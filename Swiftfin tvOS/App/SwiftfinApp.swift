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

@main
struct SwiftfinApp: App {

    @StateObject
    private var valueObservation = ValueObservation()

    init() {
        // Run-once launch migrations — BEFORE `configure()` (it reads `isLiquidGlassEnabled` at launch).
        ProwlogueLaunchMigrations.apply()
        Self.configure()

        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: UIColor.label]
    }

    var body: some Scene {
        WindowGroup {
            // Constant, full-screen OPAQUE base behind the ENTIRE app (outside the TabView). tvOS draws the
            // blurred system Home-screen wallpaper behind any transparent app content; each page paints its own
            // full-screen background INSIDE its tab, so during a tab cross-fade — the instant neither the
            // outgoing nor incoming tab fully covers the screen — that wallpaper flashed through for a frame
            // (the "OS background peeks in when switching pages" report). Anchoring one opaque layer at the root
            // fills that gap instead of the wallpaper. We use `ProwlogueAppBackground` (the SAME near-black
            // vertical gradient as the Live TV page) rather than flat black: a hard cut to pure black on a tab
            // switch reads as jarring on OLED, whereas this subtle dark gradient softens it while staying dark
            // enough to blend invisibly between the app's dark pages. Pages paint their OWN background on top
            // (Home spotlight, Live TV guide = this same gradient, and the `ProwlogueLoadingBackground` navy
            // gradient on Media / Search / Settings). Apple/community best practice: base at the ROOT, not in
            // the animating tab content.
            ZStack {
                ProwlogueAppBackground()
                    .ignoresSafeArea()

                OverlayToastView {
                    WithUserAuthentication {
                        RootView()
                    }
                }
                // Frame the whole app with the rotating SyncPlay border whenever we're in a Watch Together group.
                .syncPlayActiveBorder()
                // App-wide lower-left banners for Watch Together events (user/group join & leave). Non-interactive
                // overlay; renders nothing until an event arrives.
                .overlay {
                    SyncPlayNotificationBanner()
                }
                // Keep the Apple TV Top Shelf fresh, but ONLY while the app is in use (the shelf is off-screen
                // then, so the reload is invisible). We deliberately do NOT publish on `.background`: doing so
                // rebuilt the shelf at the exact moment the user landed on the tvOS Home screen with the shelf
                // visible, causing a flicker. Publishing on `.active` (app opened / returned from background)
                // plus HomeView's first-appear and back-to-Home publishes keeps it current before the user ever
                // leaves, so exiting to Home shows an already-settled shelf.
                .onScenePhase(.active) { publishTopShelf() }
                // Rebuild the session-scoped plumbing (WebSocket / SyncPlay / socket observer) whenever the
                // signed-in user/server changes, so nothing stays bound to the previous server. Idempotent.
                .task { Container.shared.sessionPlumbingReset().begin() }
            }
        }
    }

    /// Rebuilds the Top Shelf payload from the latest server data. Runs off the main work at background
    /// priority; the publisher itself clears the shelf when signed out, so it's safe to call any time.
    private func publishTopShelf() {
        Task(priority: .background) { @MainActor in
            await TopShelfPublisher().publish()
        }
    }
}
