//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import SwiftUI

// TODO: ensure changes on playback item change

extension VideoPlayer.PlaybackControls.Toolbar {

    struct ActionButtons: View {

        @Default(.VideoPlayer.barActionButtons)
        private var rawBarActionButtons
        @Default(.VideoPlayer.menuActionButtons)
        private var rawMenuActionButtons

        @EnvironmentObject
        private var containerState: VideoPlayerContainerState
        @EnvironmentObject
        private var manager: MediaPlayerManager

        @FocusState
        private var focusedButton: String?

        private func filteredActionButtons(_ rawButtons: [VideoPlayerActionButton]) -> [VideoPlayerActionButton] {
            var filteredButtons = rawButtons

            if manager.playbackItem?.audioStreams.isEmpty == true {
                filteredButtons.removeAll { $0 == .audio }
            }

            if manager.playbackItem?.subtitleStreams.isEmpty == true {
                filteredButtons.removeAll { $0 == .subtitles }
            }

            if manager.queue == nil {
                filteredButtons.removeAll { $0 == .autoPlay }
                filteredButtons.removeAll { $0 == .playNextItem }
                filteredButtons.removeAll { $0 == .playPreviousItem }
            }

            if manager.item.isLiveStream {
                filteredButtons.removeAll { $0 == .audio }
                filteredButtons.removeAll { $0 == .autoPlay }
                filteredButtons.removeAll { $0 == .playbackSpeed }
//                filteredButtons.removeAll { $0 == .playbackQuality }
                filteredButtons.removeAll { $0 == .subtitles }
            }

            return filteredButtons
        }

        private var barActionButtons: [VideoPlayerActionButton] {
            filteredActionButtons(rawBarActionButtons)
        }

        private var menuActionButtons: [VideoPlayerActionButton] {
            #if os(tvOS)
            // Prowlogue: the menu is the OVERFLOW of the bar — every actionable button NOT on the bar, in the
            // same canonical order. So toggling a button onto the bar removes it from the menu (no duplication),
            // and hiding it from the bar puts it in the menu. There is no separate menu configuration.
            //
            // EXCEPTION: Previous / Next are BAR-ONLY — they never appear in the menu whether enabled or not
            // (hiding them from the bar just removes them entirely).
            let notOnBar = VideoPlayerActionButton.prowlogueControlOrder
                .filter { !rawBarActionButtons.contains($0) }
                .filter { $0 != .playNextItem && $0 != .playPreviousItem }
            return filteredActionButtons(notOnBar)
            #else
            return filteredActionButtons(rawMenuActionButtons)
            #endif
        }

        @ViewBuilder
        private func view(for button: VideoPlayerActionButton) -> some View {
            switch button {
            case .aspectFill:
                AspectFill()
            case .audio:
                Audio()
            case .autoPlay:
                AutoPlay()
            #if os(iOS)
            case .gestureLock:
                GestureLock()
            #endif
            case .playbackSpeed:
                PlaybackRateMenu()
//            case .playbackQuality:
//                PlaybackQuality()
            case .playNextItem:
                PlayNextItem()
            case .playPreviousItem:
                PlayPreviousItem()
            case .subtitles:
                Subtitles()
            }
        }

        @ViewBuilder
        private var compactView: some View {
            Menu(
                L10n.menu,
                systemImage: "ellipsis.circle"
            ) {
                ForEach(
                    barActionButtons,
                    content: view(for:)
                )
                .environment(\.isInMenu, true)

                Divider()

                ForEach(
                    menuActionButtons,
                    content: view(for:)
                )
                .environment(\.isInMenu, true)
            }
        }

        @ViewBuilder
        private var regularView: some View {
            HStack(spacing: UIDevice.isTV ? 16 : 0) {
                ForEach(barActionButtons) { button in
                    view(for: button)
                        .focused($focusedButton, equals: button.rawValue)
                }

                if menuActionButtons.isNotEmpty {
                    Menu(
                        L10n.menu,
                        systemImage: UIDevice.isTV ? "ellipsis" : "ellipsis.circle"
                    ) {
                        ForEach(
                            menuActionButtons,
                            content: view(for:)
                        )
                        .environment(\.isInMenu, true)
                    }
                    .focused($focusedButton, equals: "menu")
                }
            }
            .focusSection()
            .backport
            .defaultFocus(
                $focusedButton,
                barActionButtons.first?.rawValue ?? "menu",
                priority: .userInitiated
            )
        }

        var body: some View {
            if containerState.isCompact {
                compactView
            } else {
                regularView
            }
        }
    }
}
