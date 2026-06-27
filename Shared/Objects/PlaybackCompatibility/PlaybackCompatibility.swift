//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import JellyfinAPI

enum PlaybackCompatibility: String, CaseIterable, Defaults.Serializable, Displayable {

    case auto
    case mostCompatible
    case directPlay
    /// GuamaFlix (tvOS): force the VIDEO/container to Direct Play, but keep the engine's supported audio
    /// codecs so the server transcodes audio the device can't decode (e.g. Dolby TrueHD/DTS) instead of
    /// sending an undecodable stream (= silence). MKV / high-bitrate video plays untouched, audio always
    /// works. See `DeviceProfile.build`. (Surfaced only by the tvOS "Direct Play" setting.)
    case preferDirectPlay
    case custom

    var displayTitle: String {
        switch self {
        case .auto:
            L10n.auto
        case .mostCompatible:
            L10n.compatible
        case .directPlay:
            L10n.directPlay
        case .preferDirectPlay:
            "Preferred Direct Play"
        case .custom:
            L10n.custom
        }
    }
}
