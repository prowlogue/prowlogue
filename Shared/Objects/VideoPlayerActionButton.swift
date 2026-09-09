//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// TODO: add audio/subtitle offset

enum VideoPlayerActionButton: String, CaseIterable, Displayable, Equatable, Identifiable, Storable, SystemImageable {

    case aspectFill
    case audio
    case autoPlay
    #if os(iOS)
    case gestureLock
    #endif
    case playbackSpeed
//    case playbackQuality
    case playNextItem
    case playPreviousItem
    case subtitles

    var displayTitle: String {
        switch self {
        case .aspectFill:
            L10n.aspectFill
        case .audio:
            L10n.audio
        case .autoPlay:
            L10n.autoPlay
        #if os(iOS)
        case .gestureLock:
            L10n.gestureLock
        #endif
        case .playbackSpeed:
            L10n.playbackSpeed
//        case .playbackQuality:
//            return L10n.playbackQuality
        case .playNextItem:
            L10n.playNextItem
        case .playPreviousItem:
            L10n.playPreviousItem
        case .subtitles:
            L10n.subtitles
        }
    }

    var id: String {
        rawValue
    }

    #if os(tvOS)
    var systemImage: String {
        switch self {
        case .aspectFill: "arrow.up.left.and.arrow.down.right"
        case .audio: "speaker.wave.2"
        // A stacked-play glyph reads as "keep playing the queue" (autoplay next) so it isn't mistaken for the
        // regular Play button (Prowlogue).
        case .autoPlay: "play.square.stack.fill"
        case .playbackSpeed: "speedometer"
//        case .playbackQuality: "tv.circle"
        case .playNextItem: "forward.end.fill"
        case .playPreviousItem: "backward.end.fill"
        case .subtitles: "captions.bubble.fill"
        }
    }

    var secondarySystemImage: String {
        switch self {
        case .aspectFill: "arrow.down.right.and.arrow.up.left"
        case .audio: "speaker.wave.2"
        case .autoPlay: "stop.fill"
        case .subtitles: "captions.bubble"
        default:
            systemImage
        }
    }
    #else
    var systemImage: String {
        switch self {
        case .aspectFill: "arrow.up.left.and.arrow.down.right"
        case .audio: "speaker.wave.2.fill"
        case .autoPlay: "play.circle.fill"
        case .gestureLock: "lock.circle.fill"
        case .playbackSpeed: "speedometer"
//        case .playbackQuality: "tv.circle.fill"
        case .playNextItem: "forward.end.circle.fill"
        case .playPreviousItem: "backward.end.circle.fill"
        case .subtitles: "captions.bubble.fill"
        }
    }

    var secondarySystemImage: String {
        switch self {
        case .aspectFill: "arrow.down.right.and.arrow.up.left"
        case .audio: "speaker.wave.2"
        case .autoPlay: "stop.circle"
        case .gestureLock: "lock.open.fill"
        case .subtitles: "captions.bubble"
        default:
            systemImage
        }
    }
    #endif

    static let defaultBarActionButtons: [VideoPlayerActionButton] = [
        .aspectFill,
        .autoPlay,
        .playPreviousItem,
        .playNextItem,
    ]

    static let defaultMenuActionButtons: [VideoPlayerActionButton] = [
        .audio,
        .subtitles,
        .playbackSpeed,
    ]

    /// Prowlogue (tvOS): the fixed left-to-right order for the player's control bar AND its overflow menu, used
    /// by the settings picker (`GFBarButtonsRow`) and the player (`VideoPlayer+ActionButtons`). The bar shows
    /// the enabled buttons in this order; the menu shows the rest in this order.
    static let prowlogueControlOrder: [VideoPlayerActionButton] = [
        .aspectFill,
        .autoPlay,
        .playPreviousItem,
        .playNextItem,
        .subtitles,
        .audio,
        .playbackSpeed,
    ]
}
