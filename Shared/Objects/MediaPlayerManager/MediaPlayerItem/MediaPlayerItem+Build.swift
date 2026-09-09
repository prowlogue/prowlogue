//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import Factory
import Foundation
import JellyfinAPI
import Logging

// TODO: build report of determined values for playback information
//       - transcode, video stream, path

extension MediaPlayerItem {

    /// The main `MediaPlayerItem` builder for normal online usage.
    static func build(
        for initialItem: BaseItemDto,
        mediaSource _initialMediaSource: MediaSourceInfo? = nil,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil,
        videoPlayerType: VideoPlayerType = Defaults[.VideoPlayer.videoPlayerType],
        requestedBitrate: PlaybackBitrate = Defaults[.VideoPlayer.Playback.appMaximumBitrate],
        compatibilityMode: PlaybackCompatibility = Defaults[.VideoPlayer.Playback.compatibilityMode],
        modifyItem: ((inout BaseItemDto) -> Void)? = nil
    ) async throws -> MediaPlayerItem {

        let logger = Logger.swiftfin()

        guard let itemID = initialItem.id else {
            logger.critical("No item ID!")
            throw ErrorMessage(L10n.unknownError)
        }

        guard let userSession = Container.shared.currentUserSession() else {
            logger.critical("No user session!")
            throw ErrorMessage(L10n.unknownError)
        }

        // Skip the redundant full-item fetch when the caller already handed us a COMPLETE item. The detail
        // page loads the full item (media sources, chapters, trickplay) before routing to Play, so re-running
        // `getFullItem` here — an unconditional GET /Items/{id} — only adds one server round-trip of latency to
        // the first frame for data we already hold. PARTIAL items (no media sources: deep links / synthetic
        // items) still fetch. The playable stream is (re)negotiated by the PlaybackInfo POST below either way,
        // so this changes nothing about the resolved source — only whether we pay for a duplicate metadata GET.
        var item = initialItem
        if item.mediaSources?.isNotEmpty != true {
            item = try await initialItem.getFullItem(userSession: userSession)
        }

        if let modifyItem {
            modifyItem(&item)
        }

        guard let initialMediaSource = {
            if let _initialMediaSource {
                return _initialMediaSource
            }

            if let first = item.mediaSources?.first {
                logger.trace("Using first media source for item \(itemID)")
                return first
            }

            return nil
        }() else {
            logger.error("No media sources for item \(itemID)!")
            throw ErrorMessage(L10n.unknownError)
        }

        // Both "force original video" modes (Force Direct Play and Preferred) must ALSO drop the bitrate
        // limit: `DeviceProfile.build` applies `maxBitrate` to `maxStaticBitrate`, the field Jellyfin's
        // StreamBuilder checks for Direct Play — so a high-bitrate source would otherwise be rejected (and
        // for Forced, which has no transcoding profile, playback would fail outright). `nil` = no limit.
        //
        // The native (AVPlayer) engine is chosen ONLY for HDR / Dolby Vision (see `VideoPlayerType.hybrid`).
        // For an MKV, AVPlayer can't Direct Play it (no Matroska demuxer) so Jellyfin REMUXES to fMP4/HLS. If
        // the request is uncapped, that remux COPIES the HEVC video (`-c:v copy -tag:v dvh1`), preserving Dolby
        // Vision / HDR; but ANY bitrate cap below the source forces a re-encode, which tone-maps Dolby Vision
        // down to SDR (`hevc_nvenc` + `tonemap`, tagged `hvc1`) — the exact failure we hit. HDR is all-or-
        // nothing, so the native path is ALWAYS uncapped regardless of the user's bitrate setting; only VLC
        // (`.swiftfin`) content honours the cap. (Adaptive bitrate is likewise gated off the native engine.)
        let forcesOriginalVideo = compatibilityMode == .directPlay
            || compatibilityMode == .preferDirectPlay
            || videoPlayerType == .native
        let maxBitrate: Int? = forcesOriginalVideo
            ? nil
            : try await requestedBitrate.getMaxBitrate()

        let deviceProfile = DeviceProfile.build(
            for: videoPlayerType,
            compatibilityMode: compatibilityMode,
            maxBitrate: maxBitrate
        )

        var playbackInfo = PlaybackInfoDto()
        playbackInfo.isAutoOpenLiveStream = true
        playbackInfo.deviceProfile = deviceProfile
        playbackInfo.liveStreamID = initialMediaSource.liveStreamID
        playbackInfo.maxStreamingBitrate = maxBitrate
        playbackInfo.userID = userSession.user.id
        playbackInfo.audioStreamIndex = audioStreamIndex
        playbackInfo.subtitleStreamIndex = subtitleStreamIndex

        if !item.isLiveStream {
            playbackInfo.mediaSourceID = initialMediaSource.id
        }

        let request = Paths.getPostedPlaybackInfo(
            itemID: itemID,
            playbackInfo
        )

        let response = try await userSession.client.send(request)

        let mediaSource: MediaSourceInfo? = {

            guard let mediaSources = response.value.mediaSources else { return nil }

            if let matchingTag = mediaSources.first(where: { $0.eTag == initialMediaSource.eTag }) {
                return matchingTag
            }

            for source in mediaSources {
                if let openToken = source.openToken,
                   let id = source.id,
                   openToken.contains(id)
                {
                    return source
                }
            }

            if let initialID = initialMediaSource.id,
               let matchingMediaSource = mediaSources.first(where: { $0.id == initialID })
            {
                return matchingMediaSource
            }

            logger.warning("Unable to find matching media source, defaulting to first media source")

            return mediaSources.first
        }()

        guard let mediaSource else {
            throw ErrorMessage("Unable to find media source for item")
        }

        // A multi-version item (its `mediaSources` count > 1, surfaced by our pre-play version picker) can
        // have per-version runtimes/edits — adopt the SELECTED source's runtime so the scrubber/duration
        // reflect the version actually playing, not the item's default source. (Upstream Swiftfin #2054.)
        item.runTimeTicks = mediaSource.runTimeTicks ?? item.runTimeTicks

        guard let playSessionID = response.value.playSessionID else {
            throw ErrorMessage("No associated play session ID")
        }

        let playbackURL = try Self.streamURL(
            item: item,
            mediaSource: mediaSource,
            playSessionID: playSessionID,
            userSession: userSession,
            logger: logger
        )

        let previewImageProvider: (any PreviewImageProvider)? = {
            let previewImageScrubbingSetting = StoredValues[.User.previewImageScrubbing]
            lazy var chapterPreviewImageProvider: ChapterPreviewImageProvider? = {
                if let chapters = item.fullChapterInfo, chapters.isNotEmpty {
                    return ChapterPreviewImageProvider(chapters: chapters)
                }
                return nil
            }()

            if case let PreviewImageScrubbingOption.trickplay(fallbackToChapters: fallbackToChapters) = previewImageScrubbingSetting {
                if let mediaSourceID = mediaSource.id,
                   // `trickplay[mediaSourceID]` is a dictionary keyed by generated tile WIDTH; a server may
                   // hold several resolutions. Pick the HIGHEST-width set so the scrub preview is as sharp as
                   // the server has (was `.first` — an arbitrary, often lower, resolution). Servers with only
                   // the default single (~320px) set are unaffected; a sharper preview there needs a higher
                   // server-side trickplay width, not a client change (the tile is used at native size, never
                   // downsampled — the softness is just upscaling that fixed tile to the preview size).
                   let trickplayInfo = item.trickplay?[mediaSourceID]?
                       .max(by: { ($0.value.width ?? 0) < ($1.value.width ?? 0) })
                {
                    return TrickplayPreviewImageProvider(
                        info: trickplayInfo.value,
                        itemID: itemID,
                        mediaSourceID: mediaSourceID,
                        runtime: item.runtime ?? .zero
                    )
                }

                if fallbackToChapters {
                    return chapterPreviewImageProvider
                }
            } else if previewImageScrubbingSetting == .chapters {
                return chapterPreviewImageProvider
            }

            return nil
        }()

        // Live TV (ATSC/cable) channels carry embedded CEA-608/708 closed captions that the server
        // commonly exposes as the DEFAULT subtitle track. Unlike jellyfin-web — which leaves Live TV
        // subtitles off — the player would honor that default and render captions on screen. Start live
        // streams with subtitles OFF (the viewer can still turn them on from the player's subtitle menu).
        let resolvedSubtitleStreamIndex = item.isLiveStream ? -1 : subtitleStreamIndex

        #if os(tvOS)
        // Warm the anime-detection cache (fetches the series / full item once, cached per session) BEFORE the
        // init below, so the audio resolver's synchronous verdict can apply the Anime audio preference.
        await Container.shared.prowlogueAnimeDetection().warm(for: item)
        #endif

        return .init(
            baseItem: item,
            mediaSource: mediaSource,
            playSessionID: playSessionID,
            url: playbackURL,
            requestedBitrate: requestedBitrate,
            deviceProfile: deviceProfile,
            videoPlayerType: videoPlayerType,
            initialAudioStreamIndex: audioStreamIndex,
            initialSubtitleStreamIndex: resolvedSubtitleStreamIndex,
            previewImageProvider: previewImageProvider,
            thumbnailProvider: item.getNowPlayingImage
        )
    }

    // TODO: audio type stream
    // TODO: build live tv stream from Paths.getLiveHlsStream?
    private static func streamURL(
        item: BaseItemDto,
        mediaSource: MediaSourceInfo,
        playSessionID: String,
        userSession: UserSession,
        logger: Logger
    ) throws -> URL {

        guard let itemID = item.id else {
            throw ErrorMessage("No item ID while building online media player item!")
        }

        if let transcodingPath = mediaSource.transcodingURL {
            logger.trace("Using transcoding URL for item \(itemID)")

            guard let url = userSession.client.url(path: transcodingPath) else {
                throw ErrorMessage("Unable to make transcoding URL")
            }

            return url
        }

        if item.mediaType == .video, !item.isLiveStream {

            logger.trace("Making video stream URL for item \(itemID)")

            // Build the Direct-Play stream from the SELECTED media source's tag + id (falling back to the
            // item's only when the source lacks them), not the item's. For a multi-version item, using the
            // item id as `mediaSourceID` made the server hand back its DEFAULT source — so Direct-Playing a
            // non-first version (via our pre-play version picker) played the WRONG file. (Upstream #2054;
            // matches jellyfin-web. The `??` fallbacks keep single-version behavior byte-identical.)
            let videoStreamParameters = Paths.GetVideoStreamParameters(
                isStatic: true,
                tag: mediaSource.eTag ?? item.etag,
                playSessionID: playSessionID,
                mediaSourceID: mediaSource.id ?? itemID
            )

            let videoStreamRequest = Paths.getVideoStream(
                itemID: itemID,
                parameters: videoStreamParameters
            )

            guard let videoStreamURL = userSession.client.url(with: videoStreamRequest)
            else { throw ErrorMessage("Unable to make video stream URL") }

            return videoStreamURL
        }

        logger.trace("Using media source path for item \(itemID)")

        guard let path = mediaSource.path, let streamURL = URL(
            string: path
        ) else { throw ErrorMessage("Unable to make stream URL") }

        return streamURL
    }
}
