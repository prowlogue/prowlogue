//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import JellyfinAPI
import SwiftUI

// TODO: get preview image for current manager seconds?
//       - would make scrubbing image possibly ready before scrubbing
// TODO: fix leaks
//       - made from publishers of observers not being cancelled

@MainActor
class MediaPlayerItem: ViewModel, MediaPlayerObserver {

    typealias ThumbnailProvider = () async -> UIImage?

    @Published
    var selectedAudioStreamIndex: Int? = nil {
        didSet {
            guard let selectedAudioStreamIndex, selectedAudioStreamIndex != oldValue else { return }
            manager?.setTrack(type: .audio, from: oldValue, to: selectedAudioStreamIndex)
        }
    }

    @Published
    var selectedSubtitleStreamIndex: Int? = nil {
        didSet {
            guard selectedSubtitleStreamIndex != oldValue else { return }
            manager?.setTrack(type: .subtitle, from: oldValue, to: selectedSubtitleStreamIndex)
        }
    }

    private(set) var indexMap: MediaTrackIndexMap

    private var externalSubtitlesResolved = false

    weak var manager: MediaPlayerManager? {
        didSet {
            for var o in observers {
                o.manager = manager
            }
        }
    }

    var observers: [any MediaPlayerObserver] = []

    let baseItem: BaseItemDto
    let deviceProfile: DeviceProfile
    /// The player engine (VLC `.swiftfin` vs native AVPlayer) resolved for this item — see
    /// `VideoPlayerType.hybrid(for:)`. Stored so the whole playback session (e.g. the episode
    /// auto-play queue) builds adjacent items with the SAME engine the presented view/proxy uses.
    let videoPlayerType: VideoPlayerType
    let mediaSource: MediaSourceInfo
    let playSessionID: String
    let previewImageProvider: (any PreviewImageProvider)?
    let thumbnailProvider: ThumbnailProvider?
    let url: URL

    let audioStreams: [MediaStream]
    let subtitleStreams: [MediaStream]
    let videoStreams: [MediaStream]

    /// Chapter metadata + image URLs, resolved ONCE for the playback session.
    /// `BaseItemDto.fullChapterInfo` builds an image URL (Codable query encoding) per
    /// chapter on every access — reading it per overlay body pass was the player's
    /// single biggest main-thread cost, so consumers read this stored copy instead.
    let fullChapterInfo: [ChapterInfo.FullInfo]?

    let requestedBitrate: PlaybackBitrate

    /// A custom HTTP `User-Agent` to send when playing this item's URL (external/custom IPTV sources whose
    /// providers gate on it). `nil` for normal Jellyfin playback — the proxies then behave exactly as before.
    let customUserAgent: String?

    // MARK: init

    init(
        baseItem: BaseItemDto,
        mediaSource: MediaSourceInfo,
        playSessionID: String,
        url: URL,
        requestedBitrate: PlaybackBitrate = .max,
        deviceProfile: DeviceProfile,
        videoPlayerType: VideoPlayerType = .swiftfin,
        initialAudioStreamIndex: Int? = nil,
        initialSubtitleStreamIndex: Int? = nil,
        previewImageProvider: (any PreviewImageProvider)? = nil,
        thumbnailProvider: ThumbnailProvider? = nil,
        customUserAgent: String? = nil
    ) {
        self.baseItem = baseItem
        self.mediaSource = mediaSource
        self.playSessionID = playSessionID
        self.requestedBitrate = requestedBitrate
        self.deviceProfile = deviceProfile
        self.videoPlayerType = videoPlayerType
        self.previewImageProvider = previewImageProvider
        self.thumbnailProvider = thumbnailProvider
        self.url = url
        self.customUserAgent = customUserAgent
        self.fullChapterInfo = baseItem.fullChapterInfo

        let mediaStreams = mediaSource.mediaStreams
        let isTranscoding = mediaSource.transcodingURL != nil

        // TODO: Fix External Audio Tracks & Re-Enable
        self.audioStreams = mediaStreams?.filter { $0.type == .audio && $0.isExternal != true } ?? []
        let isDirectPlayCompatibility = Defaults[.VideoPlayer.Playback.compatibilityMode] == .directPlay
        self.subtitleStreams = mediaStreams?.filter {
            $0.type == .subtitle
                && $0.deliveryMethod != .drop
                && !(isDirectPlayCompatibility
                    && $0.isExternal == true
                    && $0.isTextSubtitleStream != true)
        } ?? []
        self.videoStreams = mediaStreams?.filter { $0.type == .video } ?? []

        // Prowlogue (tvOS): honor the user's Default Audio preference by picking the track by ISO-639 language
        // code — reliable regardless of encoding / track count, since Jellyfin's server-side default can pick
        // the wrong track when several are flagged default. Passing `baseItem` also lets it apply a manual
        // audio-language choice made earlier in the same series this session. Only used when the caller didn't
        // request an explicit track, and returns nil for "Default Track" → prior behavior (no regression).
        let preferredAudioStreamIndex: Int?
        #if os(tvOS)
        preferredAudioStreamIndex = ProwlogueAudioTrackSelection.preferredAudioIndex(
            among: self.audioStreams,
            for: baseItem
        )
        #else
        preferredAudioStreamIndex = nil
        #endif

        let resolvedAudioStreamIndex = initialAudioStreamIndex
            ?? preferredAudioStreamIndex
            ?? mediaSource.defaultAudioStreamIndex
            ?? mediaSource.mediaStreams?.first(where: { $0.type == .audio })?.index ?? 0

        self.indexMap = MediaTrackIndexMap.build(
            from: mediaStreams ?? [],
            for: isTranscoding ? .transcode : .directPlay,
            selectedAudioStreamIndex: resolvedAudioStreamIndex
        )

        super.init()

        selectedAudioStreamIndex = resolvedAudioStreamIndex

        // Prowlogue (tvOS): for a detected-anime title in Subbed mode, start with subtitles in the chosen
        // Anime Subtitle Language (or OFF if set to None). Returns nil for Dubbed / non-anime → the existing
        // default behavior below (no regression). Same warmed anime cache as the audio resolver.
        let animeSubtitleStreamIndex: Int?
        // Prowlogue (tvOS): the general Subtitle Mode resolver (Off / Default / Always / Forced) — authoritative
        // for non-anime titles, so it fully governs the initial subtitle track (returns a definite index or -1).
        let modeSubtitleStreamIndex: Int?
        #if os(tvOS)
        animeSubtitleStreamIndex = ProwlogueSubtitleTrackSelection.animeSubtitleIndex(
            among: self.subtitleStreams,
            for: baseItem
        )
        modeSubtitleStreamIndex = ProwlogueSubtitleTrackSelection.initialSubtitleIndex(
            among: self.subtitleStreams,
            audioStreams: self.audioStreams,
            selectedAudioStreamIndex: selectedAudioStreamIndex
        )
        #else
        animeSubtitleStreamIndex = nil
        modeSubtitleStreamIndex = nil
        #endif

        selectedSubtitleStreamIndex = initialSubtitleStreamIndex
            ?? animeSubtitleStreamIndex
            ?? modeSubtitleStreamIndex
            ?? mediaSource.defaultSubtitleStreamIndex
            ?? -1

        observers.append(MediaProgressObserver(item: self))
    }

    /// Decides whether a track change can be performed by the player in place, or whether the server must produce a new stream.
    func isRebuildRequired(type: MediaStreamType, from oldIndex: Int?, to newIndex: Int?) -> Bool {
        let isTranscoding = mediaSource.transcodingURL != nil

        // Disabling a track is ALWAYS a local-only operation.
        guard let newIndex, newIndex != -1 else { return false }

        switch type {
        case .audio:

            // Transcodes contain a single audio track and MUST rebuild.
            if isTranscoding { return true }

            guard let newStream = audioStreams.first(where: { $0.index == newIndex }) else { return true }

            // TODO: When audio playback exists then get the type dynamically.
            return !deviceProfile.canPlay(
                type: .video,
                audioCodec: newStream.codec,
                container: mediaSource.container
            )

        case .subtitle:
            // Optional (do not guard) since this could be -1 for disabled.
            let oldStream = oldIndex.flatMap { idx in subtitleStreams.first { $0.index == idx } }

            // Transitioning away from encoded subtitles always requires a rebuild so the server stops burning them into the video.
            if oldStream?.deliveryMethod == .encode { return true }

            // Catch if the new stream doesn't exist. If non-existent this will fallback to -1 and disable locally.
            guard let newStream = subtitleStreams.first(where: { $0.index == newIndex }) else { return false }

            if newStream.isExternal == true {

                // External subtitles can only be loaded as sidecars when the profile allows external or HLS delivery for the format.
                // E.G, This should disable external PGS for VLC since VLC cannot play them.
                return !(deviceProfile.canPlay(subtitleFormat: newStream.codec, method: .external)
                    || deviceProfile.canPlay(subtitleFormat: newStream.codec, method: .hls))
            }

            // Embedded subtitles are in the source container.
            // Only reachable while direct-playing AND when the profile supports embed delivery.
            return isTranscoding || !deviceProfile.canPlay(subtitleFormat: newStream.codec, method: .embed)

        default:
            return false
        }
    }

    /// Switches an audio, subtitle track in the player without rebuilding the stream.
    func switchTrack(type: MediaStreamType, index: Int?) {
        let playerIndex: Int

        guard let mappedPlayerIndex = indexMap.playerIndex(for: index) else {
            return
        }

        playerIndex = mappedPlayerIndex

        switch type {
        case .audio:
            guard let proxy = manager?.proxy as? any MediaPlayerAudioTrackConfigurable else { return }
            proxy.setAudioStream(.init(index: playerIndex))
        case .subtitle:
            guard let proxy = manager?.proxy as? any MediaPlayerSubtitleTrackConfigurable else { return }
            proxy.setSubtitleStream(.init(index: playerIndex))
        default:
            return
        }
    }

    /// Get subtitle mapped subtitle track indexes from `playbackChildren`
    func getSubtitleIndexes(subtitleTracks: [(index: Int, title: String)]) {
        guard !externalSubtitlesResolved else { return }
        externalSubtitlesResolved = true

        let playbackChildren = subtitleStreams.sidecarSubtitles
        guard playbackChildren.isNotEmpty else { return }

        indexMap = indexMap.resolvingPlaybackChildren(
            playbackChildren,
            subtitleTracks: subtitleTracks,
            isTranscoding: mediaSource.transcodingURL != nil
        )

        switchTrack(type: .subtitle, index: selectedSubtitleStreamIndex)
    }
}
