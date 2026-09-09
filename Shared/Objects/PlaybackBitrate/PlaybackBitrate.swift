//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import Factory
import Foundation
import JellyfinAPI

// TODO: move bitrate test to `MediaPlayerManager`

enum PlaybackBitrate: Int, CaseIterable, Displayable, Storable {
    case auto = 0
    case max = 360_000_000
    case mbps120 = 120_000_000
    case mbps80 = 80_000_000
    case mbps60 = 60_000_000
    case mbps40 = 40_000_000
    case mbps20 = 20_000_000
    case mbps15 = 15_000_000
    case mbps10 = 10_000_000
    case mbps8 = 8_000_000
    case mbps6 = 6_000_000
    case mbps4 = 4_000_000
    case mbps3 = 3_000_000
    case kbps1500 = 1_500_000
    case kbps720 = 720_000
    case kbps420 = 420_000

    /// Bitrate ladder offered in the UI. "Maximum" (`.max`) is effectively uncapped (Direct Plays even
    /// high-bitrate remuxes); the default selection is `.mbps20` (see `SwiftfinDefaults`). The presets give
    /// a range between the two for constrained connections.
    static var allCases: [PlaybackBitrate] {
        [
            .max,
            .mbps120,
            .mbps80,
            .mbps60,
            .mbps40,
            .mbps20,
            .mbps15,
            .mbps10,
            .mbps8,
            .mbps6,
            .mbps4,
            .mbps3,
            .kbps1500,
            .kbps720,
            .kbps420,
            .auto
        ]
    }

    var displayTitle: String {
        switch self {
        case .auto:
            L10n.auto
        case .max:
            L10n.bitrateMax
        case .mbps120:
            L10n.bitrateMbps120
        case .mbps80:
            L10n.bitrateMbps80
        case .mbps60:
            L10n.bitrateMbps60
        case .mbps40:
            L10n.bitrateMbps40
        case .mbps20:
            L10n.bitrateMbps20
        case .mbps15:
            L10n.bitrateMbps15
        case .mbps10:
            L10n.bitrateMbps10
        case .mbps8:
            L10n.bitrateMbps8
        case .mbps6:
            L10n.bitrateMbps6
        case .mbps4:
            L10n.bitrateMbps4
        case .mbps3:
            L10n.bitrateMbps3
        case .kbps1500:
            L10n.bitrateKbps1500
        case .kbps720:
            L10n.bitrateKbps720
        case .kbps420:
            L10n.bitrateKbps420
        }
    }

    func getMaxBitrate() async throws -> Int {

        // A fixed selection uses its stated value; "Maximum" (`.max` = 360 Mbps) is effectively uncapped, so
        // high-bitrate sources Direct Play instead of being transcoded down.
        guard self == .auto else { return rawValue }

        // "Auto": measure the connection ONCE per session with the server's bitrate test, then reuse that
        // result for the rest of the session. `AutoBitrateProbe` (session-scoped) caches the first measurement;
        // it's dropped on sign-out / server switch (`SessionPlumbingReset` resets the `.session` scope), so a
        // new connection re-measures. This is the stock one-shot bandwidth test, but run a SINGLE time rather
        // than before every playback — so Auto never adds a repeated start-up delay.
        let testSize = Defaults[.VideoPlayer.appMaximumBitrateTest].rawValue
        return try await Container.shared.autoBitrateProbe().resolve(testSize: testSize)
    }
}

// MARK: - Auto bitrate probe

/// Measures connection bandwidth ONCE per session (the server's bitrate test) and caches the result, so
/// "Auto" resolves instantly on every playback after the first. Session-scoped: `SessionPlumbingReset` drops
/// the whole `.session` scope on sign-out / server switch, so a new connection re-measures. An `actor` so the
/// cache is safe to touch from the off-main stream-build task (`MediaPlayerItem.build`).
actor AutoBitrateProbe {

    private var cachedBitrate: Int?

    /// The max bitrate for "Auto": measured once, then reused for the session.
    func resolve(testSize: Int) async throws -> Int {
        if let cachedBitrate { return cachedBitrate }
        let measured = try await Self.measure(testSize: testSize)
        cachedBitrate = measured
        return measured
    }

    /// The stock one-shot bandwidth test: time a fixed-size download from the server and derive bits/sec,
    /// clamped to a sane floor/ceiling. (Formerly `PlaybackBitrate.testBitrate`; now measured once + cached.)
    private static func measure(testSize: Int) async throws -> Int {
        precondition(testSize > 0, "testSize must be greater than zero")

        guard let userSession = Container.shared.currentUserSession() else {
            throw UserSessionError.missingCurrentSession
        }

        let testStartTime = Date()
        _ = try await userSession.client.send(Paths.getBitrateTestBytes(size: testSize))
        let testDuration = Date().timeIntervalSince(testStartTime)
        let testSizeBits = Double(testSize * 8)
        let testBitrate = testSizeBits / testDuration

        return clamp(Int(testBitrate), min: 1_500_000, max: Int(Int32.max))
    }
}

extension Container {

    /// Session-scoped bandwidth probe backing "Auto" — measures once, caches for the session; reset on
    /// sign-out / server switch via `SessionPlumbingReset`'s `.session`-scope reset.
    var autoBitrateProbe: Factory<AutoBitrateProbe> {
        self { AutoBitrateProbe() }
            .scope(.session)
    }
}
