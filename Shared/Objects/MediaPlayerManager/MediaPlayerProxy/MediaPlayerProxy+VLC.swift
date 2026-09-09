//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import Foundation
import JellyfinAPI
import SwiftUI
import VLCUI

class VLCMediaPlayerProxy: VideoMediaPlayerProxy,
    MediaPlayerOffsetConfigurable,
    MediaPlayerSubtitleConfigurable
{

    let isBuffering: PublishedBox<Bool> = .init(initialValue: false)
    let videoSize: PublishedBox<CGSize> = .init(initialValue: .zero)
    let droppedFrames: PublishedBox<Int> = .init(initialValue: 0)
    let corruptedFrames: PublishedBox<Int> = .init(initialValue: 0)
    let vlcUIProxy: VLCVideoPlayer.Proxy = .init()

    weak var manager: MediaPlayerManager? {
        didSet {
            for var o in observers {
                o.manager = manager
            }
        }
    }

    var observers: [any MediaPlayerObserver] = [
        NowPlayableObserver(),
    ]

    func play() {
        vlcUIProxy.play()
    }

    func pause() {
        vlcUIProxy.pause()
    }

    func stop() {
        vlcUIProxy.stop()
    }

    func jumpForward(_ seconds: Duration) {
        let target: Duration

        if let runtime = manager?.item.runtime, let current = manager?.seconds {
            let remaining = max(.zero, runtime - current)
            target = min(seconds, remaining)
        } else {
            target = seconds
        }

        guard target > .zero else { return }

        vlcUIProxy.jumpForward(target)
    }

    func jumpBackward(_ seconds: Duration) {
        vlcUIProxy.jumpBackward(seconds)
    }

    func setRate(_ rate: Float) {
        vlcUIProxy.setRate(.absolute(rate))
    }

    func setSeconds(_ seconds: Duration) {
        vlcUIProxy.setSeconds(seconds)
    }

    func setAudioStream(_ stream: MediaStream) {
        vlcUIProxy.setAudioTrack(.absolute(stream.index ?? -1))
    }

    func setSubtitleStream(_ stream: MediaStream) {
        vlcUIProxy.setSubtitleTrack(.absolute(stream.index ?? -1))
    }

    func setAspectFill(_ aspectFill: Bool) {
        vlcUIProxy.aspectFill(aspectFill ? 1 : 0)
    }

    func setAudioOffset(_ seconds: Duration) {
        vlcUIProxy.setAudioDelay(seconds)
    }

    func setSubtitleOffset(_ seconds: Duration) {
        vlcUIProxy.setSubtitleDelay(seconds)
    }

    func setSubtitleColor(_ color: Color) {
        vlcUIProxy.setSubtitleColor(.absolute(color.uiColor))
    }

    func setSubtitleFontName(_ fontName: String) {
        vlcUIProxy.setSubtitleFont(fontName)
    }

    func setSubtitleFontSize(_ fontSize: Int) {
        vlcUIProxy.setSubtitleSize(.absolute(fontSize))
    }

    @ViewBuilder
    var videoPlayerBody: some View {
        VLCPlayerView()
            .environmentObject(vlcUIProxy)
    }
}

extension VLCMediaPlayerProxy {

    struct VLCPlayerView: View {

        @Default(.VideoPlayer.Subtitle.subtitleColor)
        private var subtitleColor
        @Default(.VideoPlayer.Subtitle.subtitleFontName)
        private var subtitleFontName
        @Default(.VideoPlayer.Subtitle.subtitleSize)
        private var subtitleSize

        @EnvironmentObject
        private var containerState: VideoPlayerContainerState
        @EnvironmentObject
        private var manager: MediaPlayerManager
        @EnvironmentObject
        private var proxy: VLCVideoPlayer.Proxy

        private var isScrubbing: Bool {
            containerState.isScrubbing
        }

        private func vlcConfiguration(for item: MediaPlayerItem) -> VLCVideoPlayer.Configuration {
            let baseItem = item.baseItem
            let mediaSource = item.mediaSource

            var configuration = VLCVideoPlayer.Configuration(url: item.url)
            // Honour the manager's requested status: normal playback is `.playing` (default) so libVLC
            // auto-starts as before. But when SyncPlay adopts this player into a PAUSED group it sets the
            // status to `.paused` BEFORE this config is built, so we open paused instead of auto-starting —
            // which previously played locally AND got re-broadcast to the whole group as an Unpause. The
            // server's later Unpause command resumes us in lockstep.
            configuration.autoPlay = manager.playbackRequestStatus == .playing

            // `network-caching` = libVLC's jitter buffer (ms) filled before/while decoding a network source.
            // VLCUI passes `options` to `VLCMedia.addOptions`, i.e. onto the Media — the value libVLC
            // actually honors for buffering (a documented libVLC nuance; the LibVLC-instance value is
            // ignored). Two very different needs:
            //  • VOD: a small 500ms buffer — still a fast first frame, with a touch more jitter headroom than
            //    the old 300ms; a hiccup just rebuffers locally from a seekable source, and startup latency is
            //    what the user feels.
            //  • LIVE TV: an IPTV/HDHR MPEG-TS feed carries real network jitter and is NOT seekable, so at
            //    300ms any jitter spike >300ms drains the buffer and VLC rebuffers — the "stutters, corrects
            //    itself, stutters again" loop. 1000ms is the VideoLAN/IPTV-community starting point: it
            //    trades ~700ms of extra tune-in (negligible against the multi-second tuner lock) for jitter
            //    tolerance, and is the OPTIMAL knob here — re-tuning (our stall watchdog) is a last resort for
            //    DEAD feeds, not a stutter fix. Clock-jitter is left at libVLC's default 5s growing window
            //    (the stable setting; `clock-jitter=0` is a low-latency tweak that HURTS live stability).
            //    Tunable: raise toward 1500–3000 if stutter persists on a poorer connection.
            let networkCaching = baseItem.isLiveStream ? 1000 : 500
            var options: [String: Any] = ["network-caching": networkCaching]

            let startSeconds = max(.zero, (baseItem.startSeconds ?? .zero) - Duration.seconds(Defaults[.VideoPlayer.resumeOffset]))

            // Resume WITHOUT the first-frame flash. `configuration.startSeconds` alone makes VLCUI PLAY from
            // the start, render the first frame(s), then SEEK to the resume point on the first time-update —
            // the visible "flash at 0, then jump". Instead we hand libVLC's demuxer a `:start-time` (seconds)
            // media option so it begins decoding AT the resume offset and never outputs a frame at 0. The
            // client-side `startSeconds` seek below is KEPT as a belt-and-suspenders fallback for any input
            // where `start-time` isn't honored; when it IS honored the later seek is a no-op (already there).
            // Live streams never resume. (Applies to direct play AND transcode — the transcode URL is not
            // pre-offset here, so both paths otherwise seek client-side and both otherwise flash.)
            if !baseItem.isLiveStream, startSeconds > .zero {
                options["start-time"] = startSeconds.seconds
            }

            // External (custom IPTV) sources may require a specific HTTP User-Agent (provider anti-leech → 403
            // otherwise). libVLC honors it as the `:http-user-agent` media option; VLCUI maps this dict onto the
            // `VLCMedia` options exactly like `network-caching` above. `nil` (server playback) leaves it unset.
            if let userAgent = item.customUserAgent, userAgent.isNotEmpty {
                options["http-user-agent"] = userAgent
            }

            configuration.options = options

            if !baseItem.isLiveStream {
                configuration.startSeconds = startSeconds

                let subtitleIndex = item.indexMap.playerIndex(for: item.selectedSubtitleStreamIndex) ?? -1

                if mediaSource.transcodingURL != nil {
                    configuration.audioIndex = .auto
                } else {
                    let audioIndex = item.indexMap.playerIndex(for: item.selectedAudioStreamIndex) ?? -1
                    configuration.audioIndex = .absolute(audioIndex)
                }

                configuration.subtitleIndex = .absolute(subtitleIndex)
            } else {
                // Live TV: subtitles OFF by default. Leaving the config at VLCUI's `.auto` made libVLC
                // auto-enable the broadcast's embedded closed-caption track (ATSC 608/708 — always present on
                // OTA channels), which no stock live-TV player shows unprompted. The build path already
                // resolves the live subtitle index to -1; this carries that into the VLC open.
                configuration.subtitleIndex = .absolute(-1)
            }

            configuration.rate = .absolute(Defaults[.VideoPlayer.Playback.playbackRate])

            #if os(tvOS)
            // Prowlogue owns the VLC player's subtitle appearance on tvOS (font / size / color / bold) from the
            // user's per-user custom picks. Replaces the stock per-key reads (kept in `#else` for the iOS target).
            ProwlogueSubtitleAppearance.apply(to: &configuration)
            #else
            configuration.subtitleSize = .absolute(25 - Defaults[.VideoPlayer.Subtitle.subtitleSize])
            configuration.subtitleColor = .absolute(Defaults[.VideoPlayer.Subtitle.subtitleColor].uiColor)
            if let font = UIFont(name: Defaults[.VideoPlayer.Subtitle.subtitleFontName], size: 1) {
                configuration.subtitleFont = .absolute(font)
            }
            #endif

            configuration.playbackChildren = item.subtitleStreams.sidecarSubtitles
                .compactMap(\.asVLCPlaybackChild)

            return configuration
        }

        var body: some View {
            if let playbackItem = manager.playbackItem, manager.state != .stopped {
                VLCVideoPlayer(configuration: vlcConfiguration(for: playbackItem))
                    .proxy(proxy)
                    .onSecondsUpdated { newSeconds, info in
                        if !isScrubbing {
                            containerState.scrubbedSeconds.value = newSeconds
                        }

                        manager.seconds = newSeconds
                        // Authoritative end-of-media signal (0…1), independent of `runtime` metadata — used by
                        // `MediaPlayerManager._ended` so autoplay doesn't freeze on a black frame when the
                        // file's true duration is shorter than the reported runtime.
                        manager.lastPlaybackPosition = info.position
                        // VLC's ACTUAL parsed media length (`media.length`, ms) — often a bit shorter than the
                        // server's runtime metadata. Drive the progress bar / timestamps off it once it's known
                        // (`> 0`), which makes the bar reach 100% and "time left" reach 0:00 at the true end;
                        // until VLC has parsed it, `playbackRuntime` falls back to the metadata runtime.
                        if info.length > 0 {
                            manager.observedDuration = .milliseconds(info.length)
                        }

                        if let proxy = manager.proxy as? any VideoMediaPlayerProxy {
                            proxy.videoSize.value = info.videoSize
                            proxy.droppedFrames.value = info.statistics.lostPictures
                            proxy.corruptedFrames.value = info.statistics.demuxCorrupted
                        }
                    }
                    .onStateUpdated { state, info in
                        manager.logger.trace("VLC state updated: \(state)")

                        switch state {
                        case .buffering,
                             .esAdded,
                             .opening:
                            // TODO: figure out when to properly set to false
                            manager.proxy?.isBuffering.value = true
                        case .ended:
                            // Live streams will send stopped/ended events
                            guard manager.playbackItem?.baseItem.isLiveStream == false else { return }
                            manager.proxy?.isBuffering.value = false
                            manager.ended()
                        case .stopped: ()
                        // Stopped is ignored as the `MediaPlayerManager`
                        // should instead call this to be stopped, rather
                        // than react to the event.
                        case .error:
                            manager.proxy?.isBuffering.value = false
                            manager.error(ErrorMessage("VLC player is unable to perform playback"))
                        case .playing:
                            manager.proxy?.isBuffering.value = false
                            manager.setPlaybackRequestStatus(status: .playing)

                            let tracks = info.subtitleTracks.map { (index: $0.index, title: $0.title) }
                            manager.playbackItem?.getSubtitleIndexes(subtitleTracks: tracks)

                            #if os(tvOS)
                            // Re-apply the Prowlogue subtitle style NOW that the SPU is live. VLCKit's text-renderer
                            // setters are most reliable applied AFTER playback starts — applying them only at config
                            // build time (as VLCUI does) can be too early for the FreeType renderer to honor. This is
                            // the working replacement for the stock live handlers below, which are dead no-ops (they
                            // cast `VLCVideoPlayer.Proxy as? MediaPlayerSubtitleConfigurable`, always nil).
                            let style = ProwlogueSubtitleAppearance.effective
                            proxy.setSubtitleSize(.absolute(style.vlcRelativeSize))
                            proxy.setSubtitleColor(.absolute(style.color))
                            if let font = style.font {
                                proxy.setSubtitleFont(.absolute(font))
                            }
                            #endif
                        case .paused:
                            manager.setPlaybackRequestStatus(status: .paused)
                        }

                        if let proxy = manager.proxy as? any VideoMediaPlayerProxy {
                            proxy.videoSize.value = info.videoSize
                        }
                    }
                    .onReceive(manager.$playbackItem) { playbackItem in
                        guard let playbackItem else { return }
                        proxy.playNewMedia(vlcConfiguration(for: playbackItem))
                    }
                    .backport
                    .onChange(of: manager.rate) { _, newValue in
                        proxy.setRate(.absolute(newValue))
                    }
                    .backport
                    .onChange(of: subtitleColor) { _, newValue in
                        if let proxy = proxy as? MediaPlayerSubtitleConfigurable {
                            proxy.setSubtitleColor(newValue)
                        }
                    }
                    .backport
                    .onChange(of: subtitleFontName) { _, newValue in
                        if let proxy = proxy as? MediaPlayerSubtitleConfigurable {
                            proxy.setSubtitleFontName(newValue)
                        }
                    }
                    .backport
                    .onChange(of: subtitleSize) { _, newValue in
                        if let proxy = proxy as? MediaPlayerSubtitleConfigurable {
                            proxy.setSubtitleFontSize(25 - newValue)
                        }
                    }
            }
        }
    }
}
