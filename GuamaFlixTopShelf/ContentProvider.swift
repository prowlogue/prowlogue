//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import TVServices

/// Minimal Top Shelf provider for the public source mirror.
/// The production GuamaFlix Top Shelf (Continue Watching / Next Up) is not shipped here.
final class ContentProvider: TVTopShelfContentProvider {

    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        nil
    }
}
