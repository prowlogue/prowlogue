//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

/// tvOS Media tab entry point. The private GuamaFlix `NativeMediaView` is not in this
/// source mirror; this wraps stock `MediaView`, which now prefers each library's
/// Jellyfin-associated Primary image on its tiles.
struct NativeMediaView: View {
    var body: some View {
        MediaView()
    }
}
