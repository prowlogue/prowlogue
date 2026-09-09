//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Factory
import SwiftUI

struct RootView: View {

    @Environment(\.localUserAuthenticationAction)
    private var authenticationAction

    #if os(tvOS)
    @Injected(\.deepLinkHandler)
    private var deepLinkHandler
    #endif

    @StateObject
    private var rootCoordinator: RootCoordinator = .init()

    var body: some View {
        ZStack {
            if rootCoordinator.root.id == RootItem.appLoading.id {
                RootItem.appLoading.content
            }

            if rootCoordinator.root.id == RootItem.mainTab.id {
                RootItem.mainTab.content
                    // Tie the main tab's SwiftUI identity to the signed-in user. `RootItem.mainTab` is a
                    // `static let` whose `content` is a single retained `MainTabView` instance, so a fast
                    // Switch-User (root churns mainTab → selectUser → mainTab before the old tab finishes
                    // tearing down) could reuse the PREVIOUS user's still-mounted tab UI — landing you back
                    // on the old user's open Settings sheet even though the session already switched. Keying
                    // identity on the user id forces SwiftUI to discard the old tree and build the new user's
                    // tab fresh. (Confirmed via switch-user logs: the session always flips correctly; only the
                    // view was stale.)
                        .id(Container.shared.currentUserSession()?.user.id)
            }

            if rootCoordinator.root.id == RootItem.selectUser.id {
                RootItem.selectUser.content
            }

            #if os(iOS)
            if rootCoordinator.root.id == RootItem.serverCheck.id {
                RootItem.serverCheck.content
            }
            #endif
        }
        .animation(.linear(duration: 0.1), value: rootCoordinator.root.id)
        .environmentObject(rootCoordinator)
        #if os(tvOS)
            .onOpenURL { url in
                Task { @MainActor in
                    await deepLinkHandler.handle(
                        url,
                        authenticationAction: authenticationAction
                    )
                }
            }
        #endif
    }
}
