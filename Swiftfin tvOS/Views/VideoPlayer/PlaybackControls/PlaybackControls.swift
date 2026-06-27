//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import Factory
import SwiftUI

extension VideoPlayer {

    struct PlaybackControls: View {

        @Default(.VideoPlayer.jumpBackwardInterval)
        var jumpBackwardInterval
        @Default(.VideoPlayer.jumpForwardInterval)
        var jumpForwardInterval

        @EnvironmentObject
        var containerState: VideoPlayerContainerState
        @EnvironmentObject
        var manager: MediaPlayerManager

        @Toaster
        var toaster: ToastProxy

        @FocusState
        private var isPlaybackProgressFocused: Bool

        @State
        var speedBoostTimer: Timer?
        @State
        var isSpeedBoosting: Bool = false
        @State
        var pendingJumpWork: DispatchWorkItem?

        // One-shot: the progress bar is `.disabled` (unfocusable) while the item is still loading, so the
        // initial focus request in `onFirstAppear` can't land and focus falls to the toolbar. We re-assert
        // focus onto the bar the moment the item becomes ready (`.playback`), then never again — so it opens
        // focused on the scrubber without ever yanking focus back later.
        @State
        private var didFocusProgressOnLoad = false

        var body: some View {
            VStack(spacing: 30) {

                Toolbar()
                    .isVisible(
                        containerState.isPresentingOverlay &&
                            !containerState.isScrubbing &&
                            !containerState.isPresentingSupplement
                    )
                    .disabled(containerState.isPresentingSupplement)

                PlaybackProgress()
                    .focused($isPlaybackProgressFocused)
                    .fixedSize(horizontal: false, vertical: true)
                    .isVisible(
                        (containerState.isPresentingOverlay || containerState.isScrubbing) &&
                            !containerState.isPresentingSupplement
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .edgePadding(.horizontal)
            // Floating contextual Skip Intro / Skip Credits affordance (GuamaFlix). Always mounted so it can
            // observe playback time; it renders the affordance (and positions itself) only while the
            // playhead is inside a media segment. See `GuamaFlixSkipSegmentButton`.
            .overlay {
                GuamaFlixSkipSegmentButton()
            }
            .animation(.easeInOut(duration: 0.25), value: containerState.isPresentingSupplement)
            .animation(.easeInOut(duration: 0.25), value: containerState.isPresentingOverlay)
            .animation(.linear(duration: 0.1), value: containerState.isScrubbing)
            .alert(L10n.closePlayer, isPresented: $containerState.isPresentingCloseConfirmation) {
                Button(L10n.cancel, role: .cancel) {}

                Button(L10n.ok, role: .destructive) {
                    manager.stop()
                }
            } message: {
                Text(L10n.closePlayerWarning)
            }
            .onFirstAppear {
                containerState.isPresentingOverlay = true
                isPlaybackProgressFocused = true
                // If the item is already playing by first appear, the focus above lands — latch so the
                // ready-state re-assert below doesn't run redundantly.
                if manager.state == .playback {
                    didFocusProgressOnLoad = true
                }

                // While in a Watch Together group, route a committed scrub through SyncPlay so it's
                // coordinated across the group (seek + hold paused + resume everyone together on the
                // server's command) instead of seeking and resuming locally ahead of the group. The hook
                // returns false when not in a group, so the player resumes normally on its own.
                containerState.onSeekCommit = { seconds in
                    Container.shared.syncPlayManager().userDidSeek(toTicks: seconds.ticks)
                }

                // Capture explicit play/pause presses for SyncPlay (broadcast the press to the group; hold
                // local playback until the server's coordinated command). Returns false when not in a group,
                // so the player toggles normally.
                containerState.onUserPlayPauseIntent = { playing in
                    Container.shared.syncPlayManager().userDidRequestPlayPause(playing: playing)
                }
            }
            .onChange(of: containerState.isPresentingOverlay) { _, _ in
                isPlaybackProgressFocused = true
            }
            // NOTE: intentionally NO "reveal the controls when playback pauses" here. Pausing while the controls
            // are hidden (via the remote's play/pause) must stay full screen — the user wants a silent toggle
            // that never summons the transport. The controls still open on first appear + on a Select/arrow
            // click, and while paused the auto-hide timer already won't dismiss them (its guard skips `.paused`).
            .onChange(of: manager.state) { _, newValue in
                // The scrubber is unfocusable while `.loadingItem`, so the initial focus request lost to the
                // toolbar. Re-assert it ONCE the item is ready (leaves loading → `.playback`), while the
                // overlay is still up, so playback opens focused on the progress bar rather than a button.
                guard !didFocusProgressOnLoad,
                      newValue == .playback,
                      containerState.isPresentingOverlay
                else { return }

                didFocusProgressOnLoad = true
                isPlaybackProgressFocused = true
            }
            .onReceive(containerState.containerView?.onPressEvent ?? .init()) { press in
                handlePressEvent(press)
            }
            .onChange(of: containerState.isProgressBarFocused) { _, newValue in
                if !newValue {
                    containerState.cancelScrub()

                    if isSpeedBoosting {
                        stopSpeedBoost()
                    }
                }
            }
        }
    }
}
