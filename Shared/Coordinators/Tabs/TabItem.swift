//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

// TODO: selected icon
@MainActor
struct TabItem: Identifiable, Hashable {

    let content: AnyView
    let id: String
    let title: String
    let systemImage: String
    let labelStyle: any LabelStyle

    init(
        id: String,
        title: String,
        systemImage: String,
        labelStyle: some LabelStyle = .titleAndIcon,
        @ViewBuilder content: () -> some View
    ) {
        self.content = AnyView(content())
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.labelStyle = labelStyle
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

extension TabItem {

    static var home: TabItem {
        TabItem(
            id: "home",
            title: L10n.home,
            systemImage: "house"
        ) {
            // tvOS uses the native GuamaFlix home. The original `HomeView()` is left intact for
            // iOS and can be restored by reverting this one line.
            #if os(tvOS)
            GuamaFlixHomeView()
            #else
            HomeView()
            #endif
        }
    }

    static func library(
        title: String,
        systemName: String,
        filters: ItemFilterCollection
    ) -> TabItem {
        TabItem(
            id: "library-\(UUID().uuidString)",
            title: title,
            systemImage: systemName
        ) {
            let viewModel = ItemLibraryViewModel(
                filters: filters
            )

            PagingLibraryView(viewModel: viewModel)
        }
    }

    #if os(tvOS)
    static var liveTV: TabItem {
        TabItem(
            id: "liveTV",
            title: L10n.liveTV,
            systemImage: "tv"
        ) {
            // tvOS landing page. Revert paths (this one line): `LiveTVGuideView()` or `NativeProgramGuideView()`.
            GuamaFlixLiveTVView()
        }
    }

    static var requests: TabItem {
        TabItem(
            id: "requests",
            title: "Requests",
            systemImage: "rectangle.stack.badge.plus"
        ) {
            // tvOS landing page (revert this one line): `RequestsView()`.
            NativeRequestsView()
        }
    }
    #endif

    static var media: TabItem {
        TabItem(
            id: "media",
            title: L10n.media,
            systemImage: "rectangle.stack.fill"
        ) {
            // tvOS landing page (revert this one line): `MediaView()`.
            #if os(tvOS)
            NativeMediaView()
            #else
            MediaView()
            #endif
        }
    }

    static var search: TabItem {
        TabItem(
            id: "search",
            title: L10n.search,
            systemImage: "magnifyingglass"
        ) {
            // tvOS landing page. Revert paths (this one line): `NativeSearchView()` or `SearchView()`.
            #if os(tvOS)
            GuamaFlixSearchView()
            #else
            SearchView()
            #endif
        }
    }

    static var settings: TabItem {
        TabItem(
            id: "settings",
            title: L10n.settings,
            systemImage: "gearshape",
            // Settings is the ONLY tab shown icon-only (just the gear) — no "Settings" text label. The
            // `title` is still set so VoiceOver/accessibility reads it; only the visible label is hidden.
            labelStyle: .iconOnly
        ) {
            // tvOS landing page (revert this one line): `SettingsView()`.
            #if os(tvOS)
            NativeSettingsView()
            #else
            SettingsView()
            #endif
        }
    }
}
