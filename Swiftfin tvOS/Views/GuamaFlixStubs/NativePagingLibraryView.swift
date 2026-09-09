//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

/// Public-mirror stand-in for the private GuamaFlix paging library UI.
struct NativePagingLibraryView<Element: Poster & Identifiable>: View {

    @ObservedObject
    var viewModel: PagingLibraryViewModel<Element>

    var body: some View {
        PagingLibraryView(viewModel: viewModel)
    }
}
