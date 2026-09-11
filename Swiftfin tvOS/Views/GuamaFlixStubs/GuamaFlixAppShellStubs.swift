//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Factory
import SwiftUI

// MARK: - Launch / shell stubs for the public source mirror

/// Branded launch screen stand-in.
struct GuamaFlixAppLoadingView: View {
    var body: some View {
        AppLoadingView()
    }
}

/// Near-black root background used behind tab transitions.
struct GuamaFlixAppBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.04, green: 0.04, blue: 0.06),
                Color.black,
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Run-once launch migrations (no-op in the public mirror).
enum GuamaFlixLaunchMigrations {
    static func apply() {}
}

/// Rebuilds session-scoped sockets when the signed-in user changes (no-op stub).
@MainActor
final class SessionPlumbingReset {
    func begin() {}
}

extension Container {
    var sessionPlumbingReset: Factory<SessionPlumbingReset> {
        self { @MainActor in SessionPlumbingReset() }
            .scope(.session)
    }
}

/// Watch Together join/leave banners (no-op stub when SyncPlay UI is unavailable).
struct SyncPlayNotificationBanner: View {
    var body: some View {
        EmptyView()
    }
}

/// Publishes Continue Watching / Next Up to the Apple TV Top Shelf.
@MainActor
struct TopShelfPublisher {
    func publish() async {}
}

extension View {
    /// Rotating SyncPlay border while in a Watch Together group (no-op stub).
    func syncPlayActiveBorder() -> some View {
        self
    }
}
