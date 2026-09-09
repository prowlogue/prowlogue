//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI
import SwiftUI

/// Public-mirror stand-in for the private GuamaFlix item / virtual-collection detail UI.
struct GuamaFlixItemView: View {

    private enum Mode {
        case item(BaseItemDto)
        case virtualCollection(title: String, id: String, itemTypes: [BaseItemKind], traits: [ItemTrait])
    }

    private let mode: Mode

    init(item: BaseItemDto) {
        mode = .item(item)
    }

    init(
        virtualCollection title: String,
        id: String,
        itemTypes: [BaseItemKind],
        traits: [ItemTrait]
    ) {
        mode = .virtualCollection(title: title, id: id, itemTypes: itemTypes, traits: traits)
    }

    var body: some View {
        switch mode {
        case let .item(item):
            ItemView(item: item)
        case let .virtualCollection(title, id, itemTypes, traits):
            let viewModel = ItemLibraryViewModel(
                title: title,
                id: id,
                filters: ItemFilterCollection(
                    itemTypes: itemTypes,
                    traits: traits
                )
            )
            PagingLibraryView(viewModel: viewModel)
        }
    }
}
