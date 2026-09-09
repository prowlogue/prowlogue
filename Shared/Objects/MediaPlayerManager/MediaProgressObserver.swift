//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Defaults
import Foundation
import JellyfinAPI

// TODO: respond properly to end of playback
//       - when item changes
// TODO: only send stop on manager stop, not per-item

class MediaProgressObserver: ViewModel, MediaPlayerObserver {

    weak var manager: MediaPlayerManager? {
        didSet {
            if let manager {
                setup(with: manager)
            }
        }
    }

    private let timer = PokeIntervalTimer()
    private var hasSentStart = false
    private var item: MediaPlayerItem?
    private var lastPlaybackRequestStatus: MediaPlayerManager.PlaybackRequestStatus = .playing

    init(item: MediaPlayerItem) {
        self.item = item
        super.init()
    }

    private func sendReport() {
        // External (custom IPTV) items aren't server items (empty `playSessionID`) — never send them to
        // `/Sessions/Playing` (it'd 400 / create a phantom now-playing). Server items always have a session.
        guard let item, item.playSessionID.isNotEmpty else { return }

        switch lastPlaybackRequestStatus {
        case .playing:
            if hasSentStart {
                sendProgressReport(for: item, seconds: manager?.seconds)
            } else {
                sendStartReport(for: item, seconds: manager?.seconds)
            }
        case .paused:
            sendProgressReport(for: item, seconds: manager?.seconds, isPaused: true)
        }
    }

    private func setup(with manager: MediaPlayerManager) {
        cancellables = []

        timer.sink { [weak self] in
            self?.sendReport()
            self?.timer.poke()
        }
        .store(in: &cancellables)

        manager.actions
            .sink { [weak self] in self?.didReceive(action: $0) }
            .store(in: &cancellables)

        manager.$playbackItem
            .sink { [weak self] in self?.playbackItemDidChange($0) }
            .store(in: &cancellables)

        manager.$playbackRequestStatus
            .sink { [weak self] in self?.playbackRequestStatusDidChange($0) }
            .store(in: &cancellables)

        // Upstream (Swiftfin #2057): end the session cleanly if the app is terminated mid-playback, so the
        // server isn't left with a running transcode / open stream until its own inactivity timeout.
        Notifications[.applicationWillTerminate]
            .publisher
            .sink { [weak self] _ in self?.endPlaybackSession() }
            .store(in: &cancellables)
    }

    /// Single teardown path for every "playback is ending" case (item change, stop, app terminate): report
    /// stop, then close the opened live stream so the IPTV tuner is freed (Prowlogue — see
    /// `closeLiveStreamIfNeeded`). Consolidated per upstream #2057.
    ///
    /// - Note: there used to be a third step here, an explicit `Paths.stopEncodingProcess` call to kill the
    /// server's encoder (upstream #2057's `stopEncoding`). That endpoint was **removed from the Jellyfin 12.0
    /// API surface**, and it turns out to have been redundant all along: `POST /Sessions/Playing/Stopped` —
    /// the `sendStopReport` below — already runs `TranscodingJobHelper.KillTranscodingJob` server-side, so
    /// the transcode is torn down by the stop report alone. The extra call was in fact a *second* kill pass
    /// over an already-disposed job, which is a known source of server-side `ObjectDisposedException`s
    /// (jellyfin#6141). Removing it is a net improvement, not a regression.
    private func endPlaybackSession() {
        guard let item else { return }
        // Skip the server stop report for external (session-less) items; the cleanup below self-guards.
        if item.playSessionID.isNotEmpty {
            sendStopReport(for: item, seconds: manager?.seconds)
        }
        closeLiveStreamIfNeeded(for: item)
    }

    private func playbackItemDidChange(_ newItem: MediaPlayerItem?) {
        timer.poke()

        if let item, newItem !== item {
            // Stop report + live-stream close for the OUTGOING item (see endPlaybackSession).
            endPlaybackSession()

            self.item = newItem
            self.hasSentStart = false
            sendReport()
        }
    }

    private func playbackRequestStatusDidChange(_ newStatus: MediaPlayerManager.PlaybackRequestStatus) {
        timer.poke()
        lastPlaybackRequestStatus = newStatus
    }

    // TODO: respond to error
    // TODO: respond properly to ended
    private func didReceive(action: MediaPlayerManager._Action) {
        switch action {
        case .stop:
            // Stop report + live-stream/tuner close (see endPlaybackSession). Freeing the
            // live stream the moment the player closes is the app's job — the server otherwise only times it
            // out minutes later, blocking a one-stream-per-account IPTV provider from tuning another channel.
            endPlaybackSession()
            timer.stop()
            cancellables = []
            item = nil
        default: ()
        }
    }

    /// Closes the server-side live stream opened for this item (Live TV channels, and any source the server
    /// opened via `isAutoOpenLiveStream`). Best-effort and OUTSIDE the debug progress-report gate — this is
    /// resource cleanup, not telemetry, so it must run even when progress reporting is disabled.
    private func closeLiveStreamIfNeeded(for item: MediaPlayerItem) {
        guard let liveStreamID = item.mediaSource.liveStreamID, liveStreamID.isNotEmpty else { return }

        Task {
            do {
                try await send(Paths.closeLiveStream(liveStreamID: liveStreamID))
            } catch {
                // Best-effort: if the close fails (network drop, already closed), the server's inactivity
                // timeout will eventually reclaim the stream.
            }
        }
    }

    private func sendStartReport(for item: MediaPlayerItem, seconds: Duration?) {

        #if DEBUG
        guard Defaults[.sendProgressReports] else { return }
        #endif

        Task {
            var info = PlaybackStateInfo()
            info.audioStreamIndex = item.selectedAudioStreamIndex
            info.itemID = item.baseItem.id
            info.liveStreamID = item.mediaSource.liveStreamID
            info.mediaSourceID = item.mediaSource.id
            info.playSessionID = item.playSessionID
            info.positionTicks = seconds?.ticks
            info.sessionID = item.playSessionID
            info.subtitleStreamIndex = item.selectedSubtitleStreamIndex

            let request = Paths.reportPlaybackStart(info)
            try await send(request)

            self.hasSentStart = true
        }
    }

    private func sendStopReport(for item: MediaPlayerItem, seconds: Duration?) {

        #if DEBUG
        guard Defaults[.sendProgressReports] else { return }
        #endif

        Task {
            var info = PlaybackStopInfo()
            info.itemID = item.baseItem.id
            info.liveStreamID = item.mediaSource.liveStreamID
            info.mediaSourceID = item.mediaSource.id
            info.playSessionID = item.playSessionID
            info.positionTicks = seconds?.ticks
            info.sessionID = item.playSessionID

            let request = Paths.reportPlaybackStopped(info)
            try await send(request)

            // Tell any open item detail page (and the home rows) to reload this item from the server, so
            // the play button flips to "Resume" and progress shows immediately after watching — instead
            // of staying stale until the app is relaunched. The view models listen for this and do a
            // non-disruptive background refresh.
            if let itemID = item.baseItem.id {
                Notifications[.itemShouldRefreshMetadata].post(itemID)
            }
        }
    }

    private func sendProgressReport(for item: MediaPlayerItem, seconds: Duration?, isPaused: Bool = false) {

        #if DEBUG
        guard Defaults[.sendProgressReports] else { return }
        #endif

        Task {
            var info = PlaybackStateInfo()
            info.audioStreamIndex = item.selectedAudioStreamIndex
            info.isPaused = isPaused
            info.itemID = item.baseItem.id
            info.liveStreamID = item.mediaSource.liveStreamID
            info.mediaSourceID = item.mediaSource.id
            info.playSessionID = item.playSessionID
            info.positionTicks = seconds?.ticks
            info.sessionID = item.playSessionID
            info.subtitleStreamIndex = item.selectedSubtitleStreamIndex

            let request = Paths.reportPlaybackProgress(info)
            try await send(request)
        }
    }
}
