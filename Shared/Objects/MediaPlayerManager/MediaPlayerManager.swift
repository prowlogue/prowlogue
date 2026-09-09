//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Defaults
import Factory
import Foundation
import JellyfinAPI
import VLCUI

// TODO: proper error catching
// TODO: be a UserSessionService?

typealias MediaPlayerManagerPublisher = LegacyEventPublisher<MediaPlayerManager?>

extension Scope {
    static let session = Cached()
}

extension Container {

    var mediaPlayerManagerPublisher: Factory<MediaPlayerManagerPublisher> {
        self { MediaPlayerManagerPublisher() }
            .singleton
    }

    var mediaPlayerManager: Factory<MediaPlayerManager> {
        self { @MainActor in
            .init(
                playbackItem: .init(
                    baseItem: .init(),
                    mediaSource: .init(),
                    playSessionID: "",
                    url: URL(string: "/")!,
                    deviceProfile: .init()
                )
            )
        }
        .scope(.session)
    }
}

import StatefulMacros

@MainActor
@Stateful
final class MediaPlayerManager: ViewModel {

    @CasePathable
    enum Action {
        case ended
        case error
        case playNewItem(provider: MediaPlayerItemProvider)
        case setBitrate(bitrate: PlaybackBitrate)
        case setPlaybackRequestStatus(status: PlaybackRequestStatus)
        case setRate(rate: Float)
        case setTrack(type: MediaStreamType, from: Int?, to: Int? = nil)
        case start
        case stop
        case togglePlayPause

        var transition: Transition {
            switch self {
            case .error:
                .to(.error)
                    .invalid(.stopped)
            case .playNewItem, .start:
                .to(.loadingItem, then: .playback)
                    .invalid(.stopped)
            case .stop:
                .to(.stopped)
            default:
                .none
                    .invalid(.stopped)
            }
        }
    }

    enum State {
        case error
        case initial
        case loadingItem
        case playback
        case stopped
    }

    /// A status indicating the player's request for media playback.
    enum PlaybackRequestStatus {

        /// The player requests media playback
        case playing

        /// The player is paused
        case paused
    }

    @Published
    var playbackItem: MediaPlayerItem? = nil {
        didSet {
            if let playbackItem {
                self.item = playbackItem.baseItem
                seconds = playbackItem.baseItem.startSeconds ?? .zero
                lastPlaybackPosition = 0
                observedDuration = nil
                playbackItem.manager = self
                setSupplements()

                logger.info(
                    "Playing new item",
                    metadata: [
                        "itemID": .stringConvertible(playbackItem.baseItem.id ?? "Unknown"),
                        "itemTitle": .stringConvertible(playbackItem.baseItem.displayTitle),
                        "url": .stringConvertible(playbackItem.url.absoluteString),
                        "isTranscoding": .stringConvertible(playbackItem.mediaSource.transcodingURL != nil),
                    ]
                )

                Task { _ = await playbackItem.previewImageProvider?.image(for: seconds) }
            }
        }
    }

    @Published
    private(set) var item: BaseItemDto
    @Published
    private(set) var playbackRequestStatus: PlaybackRequestStatus = .playing
    @Published
    var rate: Float = Defaults[.VideoPlayer.Playback.playbackRate] {
        didSet {
            Defaults[.VideoPlayer.Playback.playbackRate] = rate
        }
    }

    @Published
    var queue: AnyMediaPlayerQueue? = nil

    @Published
    var supplements: [any MediaPlayerSupplement] = []

    // TODO: replace with graph dependency package
    private func setSupplements() {
        self.supplements = Defaults[.VideoPlayer.supplements].compactMap { kind -> (any MediaPlayerSupplement)? in
            switch kind {
            case .info:
                return MediaInfoSupplement(item: item)
            case .chapters:
                guard let chapters = item.fullChapterInfo, chapters.isNotEmpty else { return nil }
                return MediaChaptersSupplement(chapters: chapters)
            case .queue:
                return queue
            case .people:
                guard let people = item.people?.filter({ $0.type?.isSupported == true }), people.isNotEmpty else { return nil }
                return MediaPeopleSupplement(people: people)
            case .playbackInformation:
                guard let itemID = item.id else { return nil }
                return PlaybackInformationSupplement(itemID: itemID)
            }
        }
    }

    /// The current seconds media playback is set to.
    let secondsBox: PublishedBox<Duration> = .init(initialValue: .zero)

    /// The player's own playback position as a 0…1 fraction of the media, reported by the proxy. This is the
    /// authoritative "did playback actually reach the end" signal — independent of the `runtime` METADATA,
    /// which can be longer than the file's true duration (which made autoplay silently freeze on a black
    /// frame; see `_ended`). Reset to 0 for each new item.
    var lastPlaybackPosition: Float = 0

    /// The player's ACTUAL parsed media length, as reported by the proxy (only the VLC proxy sets this — the
    /// AVPlayer path leaves it nil and keeps using the metadata runtime). The server's `runtime` METADATA
    /// (Jellyfin `RunTimeTicks`) is frequently a little longer than the real file, which leaves the progress
    /// bar short of 100% and "time left" above 0:00 at the true end. Reset per item; drives `playbackRuntime`.
    var observedDuration: Duration?

    /// The runtime the playback UI (progress bar, timestamps) should measure against. Best practice for a
    /// Jellyfin/VLC client is to drive the VISUAL bar off the player's own parsed length once it's known, and
    /// fall back to the server metadata until then (so there's never a broken bar while VLC is still parsing).
    var playbackRuntime: Duration? {
        if let observedDuration, observedDuration > .zero {
            return observedDuration
        }
        return item.runtime
    }

    var seconds: Duration {
        get { secondsBox.value }
        set { secondsBox.value = newValue }
    }

    /// Holds a weak reference to the current media player proxy.
    weak var proxy: (any MediaPlayerProxy)? {
        didSet {
            if var proxy {
                proxy.manager = self
            }
        }
    }

    private var initialMediaPlayerItemProvider: MediaPlayerItemProvider?

    // MARK: init

//    static let empty: MediaPlayerManager = .init()

//    override private init() {
//        self.item = .init()
//        self.state = .stopped
//        super.init()
//    }

    init(
        item: BaseItemDto,
        queue: (any MediaPlayerQueue)? = nil,
        mediaPlayerItemProvider: @escaping MediaPlayerItemProviderFunction
    ) {
        self.item = item
        self.queue = queue.map { AnyMediaPlayerQueue($0) }
        self.state = .loadingItem
        self.initialMediaPlayerItemProvider = .init(
            item: item,
            function: mediaPlayerItemProvider
        )
        super.init()

        self.queue?.manager = self
    }

    init(
        playbackItem: MediaPlayerItem,
        queue: (any MediaPlayerQueue)? = nil
    ) {
        self.item = playbackItem.baseItem
        self.queue = queue.map { AnyMediaPlayerQueue($0) }
        self.state = .playback
        super.init()

        self.queue?.manager = self
        self.playbackItem = playbackItem
    }

    @Function(\Action.Cases.ended)
    private func _ended() async throws {
        // `.ended` should represent the NATURAL end of playback. Some players (notably VLC) can emit it a
        // little early, or — for transcodes — at a mid-stream data gap, so verify we're actually at the end
        // before auto-advancing.
        //
        // We PREFER the player's own position fraction (0…1), which is authoritative and independent of the
        // `runtime` METADATA. The old check (`runtime - seconds <= 1s`) trusted only the metadata: when a
        // file's true duration is shorter than the reported runtime (or the last position update lags the
        // real end), that window never matched, so autoplay silently did nothing and the player FROZE on a
        // black frame. The position fraction fixes that for every case; the runtime window is only a fallback.
        let reachedEnd: Bool = if lastPlaybackPosition >= 0.95 {
            true
        } else if let runtime = item.runtime {
            (runtime - seconds) <= .seconds(5)
        } else {
            // No position and no runtime to judge by — treat the player's end as final rather than freezing.
            true
        }

        guard reachedEnd else {
            // Reported ended well before the end (e.g. a transcode data gap) → ignore, don't advance.
            return
        }

        // An explicit-mode queue (e.g. shuffle) forces auto-advance regardless of the user's
        // `enableNextEpisodeAutoPlay` server setting; otherwise honor that setting.
        let autoPlayEnabled = try authenticatedUser.data.configuration?.enableNextEpisodeAutoPlay == true
        if let nextItem = queue?.nextItem, queue?.forcesAutoAdvance == true || autoPlayEnabled {
            await self.playNewItem(provider: nextItem)
        } else {
            await self.stop()
        }
    }

    @Function(\Action.Cases.error)
    private func onError(_ error: Error) async throws {
        if let playbackItem {
            logger.error(
                "Error while playing item",
                metadata: [
                    "error": .stringConvertible(error.localizedDescription),
                    "itemID": .stringConvertible(playbackItem.baseItem.id ?? "Unknown"),
                    "itemTitle": .stringConvertible(playbackItem.baseItem.displayTitle),
                    "url": .stringConvertible(playbackItem.url.absoluteString),
                ]
            )
        } else {
            logger.error(
                "Error with no playback item",
                metadata: [
                    "error": .stringConvertible(error.localizedDescription),
                    "itemID": .stringConvertible(item.id ?? "Unknown"),
                    "itemTitle": .stringConvertible(item.displayTitle),
                ]
            )
        }

        proxy?.stop()
        Container.shared.mediaPlayerManagerPublisher().send(nil)
        Container.shared.mediaPlayerManager.reset()
    }

    @Function(\Action.Cases.playNewItem)
    private func _playNewItem(_ provider: MediaPlayerItemProvider) async throws {
        item = provider.item
        setSupplements()
        proxy?.stop()
        playbackItem = try await provider()
    }

    @Function(\Action.Cases.setBitrate)
    private func _setBitrate(_ requestedBitrate: PlaybackBitrate) async throws {
        guard let currentItem = playbackItem else { return }

        try await updateMediaPlayerItem(
            currentItem: currentItem,
            requestedBitrate: requestedBitrate
        )
    }

    @Function(\Action.Cases.setPlaybackRequestStatus)
    private func set(_ status: PlaybackRequestStatus) {
        if self.playbackRequestStatus != status {
            self.playbackRequestStatus = status

            switch status {
            case .paused:
                proxy?.pause()
            case .playing:
                proxy?.play()
            }
        }
    }

    @Function(\Action.Cases.setRate)
    private func set(_ rate: Float) {
        if self.rate != rate {
            self.rate = rate
        }
    }

    @Function(\Action.Cases.setTrack)
    private func _setTrack(_ type: MediaStreamType, _ oldIndex: Int?, _ newIndex: Int?) async throws {
        guard let playbackItem else {
            logger.warning("MediaPlayerManager.SetTrack call with an invalid playbackItem")
            return
        }

        switch type {
        case .audio:
            guard playbackItem.audioStreams.contains(where: { $0.index == oldIndex }) else {
                logger.warning("MediaPlayerManager.SetTrack call with an invalid audio track index")
                return
            }

            if playbackItem.isRebuildRequired(type: .audio, from: oldIndex, to: newIndex) {
                try await updateMediaPlayerItem(
                    currentItem: playbackItem,
                    audioStreamIndex: newIndex
                )
            } else {
                playbackItem.switchTrack(type: .audio, index: newIndex)
            }
        case .subtitle:
            guard newIndex == -1 || playbackItem.subtitleStreams.contains(where: { $0.index == newIndex }) else {
                logger.warning("MediaPlayerManager.SetTrack call with an invalid subtitle track index")
                return
            }

            if playbackItem.isRebuildRequired(type: .subtitle, from: oldIndex, to: newIndex) {
                try await updateMediaPlayerItem(
                    currentItem: playbackItem,
                    subtitleStreamIndex: newIndex
                )
            } else {
                playbackItem.switchTrack(type: .subtitle, index: newIndex)
            }
        default:
            logger.warning("MediaPlayerManager.SetTrack called with unsupported type: \(String(describing: type))")
        }
    }

    @Function(\Action.Cases.start)
    private func _start() async throws {
        guard let initialMediaPlayerItemProvider else {
            await self.stop()
            return
        }
        self.initialMediaPlayerItemProvider = nil
        playbackItem = try await initialMediaPlayerItemProvider()
    }

    // TODO: remove playback item?
    //       - check that observers would respond correctly to stopping
    @Function(\Action.Cases.stop)
    private func _stop() async throws {
        await self.cancel()

        proxy?.stop()
        Container.shared.mediaPlayerManagerPublisher().send(nil)
        Container.shared.mediaPlayerManager.reset()
    }

    @Function(\Action.Cases.togglePlayPause)
    private func _togglePlayPause() {
        switch playbackRequestStatus {
        case .playing:
            setPlaybackRequestStatus(status: .paused)
        case .paused:
            setPlaybackRequestStatus(status: .playing)
        }
    }

    /// Rebuilds the playback item with new stream indexes / bitrate.
    /// Stops the current proxy, requests new playback info from the server, and starts playback with the new configuration.
    ///
    /// Rebuilds the current item
    private func updateMediaPlayerItem(
        currentItem: MediaPlayerItem,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil,
        requestedBitrate: PlaybackBitrate? = nil
    ) async throws {

        // Capture the current playback position before stopping
        let currentSeconds = self.seconds

        logger.info(
            "Rebuilding Media Player Item",
            metadata: [
                "audioIndex": "\(audioStreamIndex ?? -1)",
                "subtitleIndex": "\(subtitleStreamIndex ?? -1)",
                "currentSeconds": "\(currentSeconds)",
            ]
        )

        proxy?.stop()

        let newItem = try await MediaPlayerItem.build(
            for: currentItem.baseItem,
            mediaSource: currentItem.mediaSource,
            audioStreamIndex: audioStreamIndex ?? currentItem.selectedAudioStreamIndex,
            subtitleStreamIndex: subtitleStreamIndex ?? currentItem.selectedSubtitleStreamIndex,
            // Keep the SESSION's resolved engine (the presented proxy/view is fixed for the session — see the
            // hybrid AVPlayer/VLC split). Without this the rebuild would fall back to the default engine's
            // `DeviceProfile`, which could mismatch the mounted proxy (e.g. a VLC-profile stream fed to the
            // native AVPlayer). Matters for the adaptive-bitrate re-negotiation, which rebuilds mid-session.
            videoPlayerType: currentItem.videoPlayerType,
            requestedBitrate: requestedBitrate ?? currentItem.requestedBitrate,
            modifyItem: { item in
                if item.userData == nil {
                    // `key` became non-optional in jellyfin-sdk-swift 3.x (Jellyfin 12.0 surface). This is a
                    // synthetic, client-only user-data object that exists solely to carry the resume
                    // position into the rebuild — it is never sent back to the server, so an empty key is
                    // correct (and is what upstream uses).
                    item.userData = UserItemDataDto(key: "")
                }
                item.userData?.playbackPositionTicks = currentSeconds.ticks
            }
        )

        logger.info(
            "Built new playback item",
            metadata: [
                "playSessionID": "\(newItem.playSessionID)",
                "isTranscoding": "\(newItem.mediaSource.transcodingURL != nil)",
                "url": "\(newItem.url.absoluteString)",
            ]
        )

        self.playbackItem = newItem
        self.seconds = currentSeconds
    }
}
