//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import JellyfinAPI

extension DeviceProfile {

    static func build(
        for videoPlayer: VideoPlayerType,
        compatibilityMode: PlaybackCompatibility,
        maxBitrate: Int? = nil
    ) -> DeviceProfile {

        var deviceProfile: DeviceProfile = .init()

        // MARK: - Video Player Specific Logic

        deviceProfile.codecProfiles = videoPlayer.codecProfiles
        deviceProfile.subtitleProfiles = videoPlayer.subtitleProfiles

        // MARK: - DirectPlay & Transcoding Profiles

        // AVPlayer (`.native`) has NO Matroska demuxer — it can only open a fixed container set (mp4/mov/
        // mpeg-ts/…), never MKV. So when a "force original video" mode advertises "any container", the server
        // Direct Plays an MKV remux that the native engine can't open → infinite spinner (HDR) / black screen
        // (Dolby Vision). Constrain the forced container to the engine's OWN demuxable set so incompatible
        // containers (MKV, …) fall through to the transcoding profile — a cheap container REMUX to fMP4/HLS that
        // keeps the HEVC video + HDR/Dolby Vision intact. VLC demuxes essentially anything, so it stays "any
        // container" (`nil`) to avoid needless remuxes. (See DeviceProfile forced/preferred cases below.)
        let forcedDirectPlayContainers: String? = {
            guard videoPlayer == .native else { return nil }
            let containers = videoPlayer.directPlayProfiles
                .compactMap(\.container)
                .flatMap { $0.split(separator: ",").map(String.init) }
            return containers.isEmpty ? nil : Set(containers).sorted().joined(separator: ",")
        }()

        switch compatibilityMode {
        case .auto:
            deviceProfile.directPlayProfiles = videoPlayer.directPlayProfiles
            deviceProfile.transcodingProfiles = videoPlayer.transcodingProfiles

        case .mostCompatible:
            deviceProfile.directPlayProfiles = PlaybackCompatibility.Video.compatibilityDirectPlayProfile
            deviceProfile.transcodingProfiles = PlaybackCompatibility.Video.compatibilityTranscodingProfile

        case .directPlay:
            // Force original video, but only within containers THIS engine can actually demux (see
            // `forcedDirectPlayContainers`). For `.native` (AVPlayer) this excludes MKV etc.; keep the remux
            // transcoding profile as the fallback so those still play (container-copy → fMP4/HLS, no re-encode,
            // HDR/DV preserved) instead of black-screening. VLC keeps pure forced Direct Play (any container,
            // no transcode) since it demuxes everything.
            deviceProfile.directPlayProfiles = [
                DirectPlayProfile(container: forcedDirectPlayContainers, type: .video),
            ]
            if videoPlayer == .native {
                deviceProfile.transcodingProfiles = videoPlayer.transcodingProfiles
            }

        case .preferDirectPlay:
            // Like `.directPlay`, accept ANY container/video codec so the original video Direct Plays — but
            // keep THIS engine's supported audio codecs (so e.g. Dolby TrueHD/DTS aren't claimed) and KEEP
            // the transcoding profiles. The server then copies the video and transcodes only the audio the
            // device can't decode, instead of sending an undecodable stream (= silence). Audio CSV is the
            // union of the engine's own Direct Play audio codecs; container/videoCodec left nil = "any".
            let supportedAudioCodecs = videoPlayer.directPlayProfiles
                .compactMap(\.audioCodec)
                .flatMap { $0.split(separator: ",").map(String.init) }
            let audioCSV = Set(supportedAudioCodecs).sorted().joined(separator: ",")
            // Container constrained to what the engine can demux (nil = any, for VLC). On `.native` this stops
            // the server from Direct Playing an MKV that AVPlayer can't open — those remux via the transcoding
            // profile below instead. `videoCodec` left nil = any, so the original video still Direct Plays where
            // the container allows.
            deviceProfile.directPlayProfiles = [
                DirectPlayProfile(
                    audioCodec: audioCSV.isEmpty ? nil : audioCSV,
                    container: forcedDirectPlayContainers,
                    type: .video
                ),
            ]
            deviceProfile.transcodingProfiles = videoPlayer.transcodingProfiles

        case .custom:
            let customProfileMode = Defaults[.VideoPlayer.Playback.customDeviceProfileAction]
            let playbackDeviceProfile = StoredValues[.User.customDeviceProfiles]

            if customProfileMode == .add {
                deviceProfile.directPlayProfiles = videoPlayer.directPlayProfiles
                deviceProfile.transcodingProfiles = videoPlayer.transcodingProfiles
            } else {
                deviceProfile.directPlayProfiles = []

                // Only clear the Transcoding Profiles if one of the CustomProfiles is active as a Transcoding Profile
                if playbackDeviceProfile.contains(where: { $0.useAsTranscodingProfile == true }) {
                    deviceProfile.transcodingProfiles = []
                } else {
                    deviceProfile.transcodingProfiles = videoPlayer.transcodingProfiles
                }
            }

            for profile in playbackDeviceProfile where profile.type == .video {
                deviceProfile.directPlayProfiles?.append(profile.directPlayProfile)

                if profile.useAsTranscodingProfile {
                    deviceProfile.transcodingProfiles?.append(profile.transcodingProfile)
                }
            }
        }

        // MARK: - Assign the Bitrate if provided

        if let maxBitrate {
            deviceProfile.maxStaticBitrate = maxBitrate
            deviceProfile.maxStreamingBitrate = maxBitrate
            deviceProfile.musicStreamingTranscodingBitrate = maxBitrate
        }

        return deviceProfile
    }

    // MARK: - Playback Capability Queries

    /// Whether any `DirectPlayProfile` allows media with this audio codec in the given container to be played directly.
    func canPlay(type: DlnaProfileType, audioCodec: String?, container: String?) -> Bool {
        (directPlayProfiles ?? []).contains { profile in
            profile.type == type
                && profileContains(profile: profile.audioCodec, audioCodec)
                && profileContains(profile: profile.container, container)
        }
    }

    /// Whether any `DirectPlayProfile` allows media with this video codec in the given container to be played directly.
    func canPlay(type: DlnaProfileType, videoCodec: String?, container: String?) -> Bool {
        (directPlayProfiles ?? []).contains { profile in
            profile.type == type
                && profileContains(profile: profile.videoCodec, videoCodec)
                && profileContains(profile: profile.container, container)
        }
    }

    /// Whether any `SubtitleProfile` allows this format to be delivered via the given method.
    func canPlay(subtitleFormat: String?, method: SubtitleDeliveryMethod) -> Bool {
        guard let subtitleFormat = subtitleFormat?.lowercased() else { return false }
        return (subtitleProfiles ?? []).contains { profile in
            profile.method == method
                && profile.format?.lowercased() == subtitleFormat
        }
    }

    /// Parse & check membership like this is CSV as that's the format we send to the server.
    private func profileContains(profile: String?, _ candidate: String?) -> Bool {
        guard let profile else { return true }
        guard let candidate = candidate?.lowercased() else { return false }
        return profile
            .lowercased()
            .split(separator: ",")
            .contains { $0.trimmingCharacters(in: .whitespaces) == candidate }
    }
}
