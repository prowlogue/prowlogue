//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import Pulse

extension NetworkLogger {

    static func swiftfin() -> NetworkLogger {
        var configuration = NetworkLogger.Configuration()

        // Keep the request/response LIST in the Logs console but DROP request/response BODIES before Pulse
        // persists them: `LoggerStore.storeBlob` does a Core Data dedup-fetch + write per body — pure
        // diagnostic overhead with no user-visible benefit. Nil-ing both bodies skips the blob store while
        // preserving URL/status/metrics, and also guarantees credential bodies (AuthenticateByName /
        // Password) are never written to disk, so per-field redaction isn't needed.
        configuration.willHandleEvent = { event -> LoggerStore.Event? in
            if case var LoggerStore.Event.networkTaskCompleted(task) = event {
                task.requestBody = nil
                task.responseBody = nil
                return LoggerStore.Event.networkTaskCompleted(task)
            }

            return event
        }

        return NetworkLogger(configuration: configuration)
    }
}
