//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

/// Public-mirror stand-in for the private Seerr / Requests tab.
/// The Requests UI is not included in this source mirror.
struct NativeRequestsView: View {
    var body: some View {
        Text("Requests")
            .font(.title2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
