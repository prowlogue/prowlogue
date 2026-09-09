//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

extension VideoPlayerType {

    // MARK: - Direct Play

    @ArrayBuilder<DirectPlayProfile>
    static var _nativeDirectPlayProfiles: [DirectPlayProfile] {

        DirectPlayProfile(type: .video) {
            AudioCodec.aac
            AudioCodec.ac3
            AudioCodec.alac
            AudioCodec.eac3
            AudioCodec.flac
        } videoCodecs: {

            VideoCodec.h264
            VideoCodec.mpeg4

            if PlaybackCapabilities.supportsAV1 {
                VideoCodec.av1
            }
            if PlaybackCapabilities.supportsHEVC {
                VideoCodec.hevc
            }
            if PlaybackCapabilities.supportsVP9 {
                VideoCodec.vp9
            }

        } containers: {
            MediaContainer.mp4
            MediaContainer.m4v
        }

        DirectPlayProfile(type: .video) {
            AudioCodec.aac
            AudioCodec.ac3
            AudioCodec.alac
            AudioCodec.eac3
            AudioCodec.mp3
            AudioCodec.pcm_s16be
            AudioCodec.pcm_s16le
            AudioCodec.pcm_s24be
            AudioCodec.pcm_s24le
        } videoCodecs: {

            VideoCodec.h264
            VideoCodec.mjpeg
            VideoCodec.mpeg4

            if PlaybackCapabilities.supportsHEVC {
                VideoCodec.hevc
            }

        } containers: {
            MediaContainer.mov
        }

        DirectPlayProfile(type: .video) {
            AudioCodec.aac
            AudioCodec.ac3
            AudioCodec.eac3
            AudioCodec.mp3
        } videoCodecs: {

            VideoCodec.h264

            if PlaybackCapabilities.supportsHEVC {
                VideoCodec.hevc
            }

        } containers: {
            MediaContainer.mpegts
        }

        DirectPlayProfile(type: .video) {
            AudioCodec.aac
            AudioCodec.amr_nb
        } videoCodecs: {
            VideoCodec.h264
            VideoCodec.mpeg4
        } containers: {
            MediaContainer.threeG2
            MediaContainer.threeGP
        }

        DirectPlayProfile(type: .video) {
            AudioCodec.pcm_mulaw
            AudioCodec.pcm_s16le
        } videoCodecs: {
            VideoCodec.mjpeg
        } containers: {
            MediaContainer.avi
        }
    }

    // MARK: - Transcoding

    @ArrayBuilder<TranscodingProfile>
    static var _nativeTranscodingProfiles: [TranscodingProfile] {

        TranscodingProfile(
            isBreakOnNonKeyFrames: true,
            context: .streaming,
            enableSubtitlesInManifest: true,
            maxAudioChannels: "8",
            minSegments: 2,
            protocol: MediaStreamProtocol.hls,
            type: .video
        ) {
            AudioCodec.aac
            AudioCodec.ac3
            AudioCodec.alac
            AudioCodec.eac3
            AudioCodec.flac
        } videoCodecs: {

            /// - Note: Transcode Profiles prioritizes codecs by order
            if PlaybackCapabilities.supportsAV1 {
                VideoCodec.av1
            }
            if PlaybackCapabilities.supportsHEVC {
                VideoCodec.hevc
            }

            VideoCodec.h264
            VideoCodec.mpeg4

        } containers: {
            MediaContainer.mp4
        }
    }

    // MARK: - Subtitle

    @ArrayBuilder<SubtitleProfile>
    static var _nativeSubtitleProfiles: [SubtitleProfile] {

        SubtitleProfile.build(method: .embed) {
            SubtitleFormat.cc_dec
            SubtitleFormat.ttml
        }

        SubtitleProfile.build(method: .encode) {
            SubtitleFormat.dvbsub
            SubtitleFormat.dvdsub
            SubtitleFormat.pgssub
            SubtitleFormat.xsub
        }

        SubtitleProfile.build(method: .hls) {
            SubtitleFormat.vtt
        }
    }

    // MARK: - Codec Profiles

    @ArrayBuilder<CodecProfile>
    static var _nativeCodecProfiles: [CodecProfile] {

        CodecProfile(
            codec: VideoCodec.h264.rawValue,
            type: .video,
            conditions: {
                _h264BaseConditions
                ProfileCondition(
                    condition: .equalsAny,
                    isRequired: false,
                    property: .videoRangeType
                ) {
                    VideoRangeType.sdr
                    VideoRangeType.doviWithSDR
                }
                /// AVPlayer has no deinterlacer — interlaced AVC must be transcoded (upstream #2128).
                ProfileCondition(
                    condition: .notEquals,
                    isRequired: false,
                    property: .isInterlaced,
                    value: "true"
                )
            }
        )

        CodecProfile(
            codec: VideoCodec.hevc.rawValue,
            type: .video,
            conditions: {
                _hevcBaseConditions
                ProfileCondition(
                    condition: .equalsAny,
                    isRequired: false,
                    property: .videoRangeType
                ) {
                    nativeHDRProfiles
                }
                /// Upstream (Swiftfin #2109): AVFoundation only decodes HEVC whose parameter sets (VPS/SPS/PPS)
                /// live out-of-band in the sample description — i.e. the `hvc1` / `dvh1` codec tags. The `hev1`
                /// and `dvhe` tags carry them inline in the bitstream and are rejected by the whole Apple media
                /// stack (ffmpeg/libx265 emits `hev1` by default, so these files are common). Without this
                /// condition the server Direct Plays such a file to AVPlayer and playback fails outright —
                /// which matters doubly here, since `VideoPlayerType.hybrid(for:)` routes HDR/DoVi to `.native`.
                /// Requiring the tag makes the server remux to an `hvc1` fMP4 instead (video copied, HDR/DV kept).
                ProfileCondition(
                    condition: .equalsAny,
                    isRequired: true,
                    property: .videoCodecTag
                ) {
                    "hvc1"
                    "dvh1"
                }
                /// Apple TV 4K decodes HEVC up to 4K60; anything faster needs a transcode.
                ProfileCondition(
                    condition: .lessThanEqual,
                    isRequired: true,
                    property: .videoFramerate,
                    value: "60"
                )
            }
        )

        CodecProfile(
            codec: VideoCodec.av1.rawValue,
            type: .video,
            conditions: {
                ProfileCondition(
                    condition: .notEquals,
                    isRequired: false,
                    property: .isAnamorphic,
                    value: "true"
                )
                ProfileCondition(
                    condition: .notEquals,
                    isRequired: false,
                    property: .isInterlaced,
                    value: "true"
                )
                ProfileCondition(
                    condition: .equalsAny,
                    isRequired: false,
                    property: .videoRangeType
                ) {
                    nativeHDRProfiles
                }
            }
        )
    }

    @ArrayBuilder<VideoRangeType>
    private static var nativeHDRProfiles: [VideoRangeType] {

        VideoRangeType.sdr
        VideoRangeType.doviWithSDR

        if PlaybackCapabilities.supportsHLG {
            VideoRangeType.hlg
            VideoRangeType.doviWithHLG
        }

        if PlaybackCapabilities.supportsHDR10 {
            VideoRangeType.hdr10
            VideoRangeType.hdr10Plus
        }

        if PlaybackCapabilities.supportsHDR10 || PlaybackCapabilities.supportsDolbyVision {
            VideoRangeType.doviWithHDR10
            VideoRangeType.doviWithHDR10Plus
            /// Upstream (Swiftfin #2134): `doviWithEL` is Dolby Vision Profile 7 (dual-layer, BL + enhancement
            /// layer). Claiming it stops the server stripping the DV layer and remuxing — the base layer is
            /// HEVC Main10 and plays; the EL is simply ignored. Consistent with the `doviWithELHDR10Plus`
            /// claim already below, which is the strictly harder case.
            VideoRangeType.doviWithEL
            VideoRangeType.doviWithELHDR10Plus
        }

        if PlaybackCapabilities.supportsDolbyVision {
            VideoRangeType.dovi
        }
    }
}
