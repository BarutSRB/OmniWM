// SPDX-License-Identifier: GPL-2.0-only
import CoreGraphics
import Foundation
import OSLog

private let eventTapTeardownLog = Logger(
    subsystem: "com.omniwm.core",
    category: "EventTapTeardown"
)

struct EventTapTeardownOperations {
    var disableTap: (CFMachPort) -> Void
    var removeRunLoopSource: (CFRunLoop, CFRunLoopSource, CFRunLoopMode) -> Void
    var invalidateTap: (CFMachPort) -> Void

    static var live: EventTapTeardownOperations {
        EventTapTeardownOperations(
            disableTap: { tap in
                CGEvent.tapEnable(tap: tap, enable: false)
            },
            removeRunLoopSource: { runLoop, source, mode in
                CFRunLoopRemoveSource(runLoop, source, mode)
            },
            invalidateTap: { tap in
                CFMachPortInvalidate(tap)
            }
        )
    }
}

enum EventTapTeardown {
    /// Tear down in the order that closes input intake before invalidating the
    /// Mach port: disable delivery, unschedule the run-loop source, invalidate
    /// the port, then release Swift's references.
    static func tearDown(
        tap: inout CFMachPort?,
        runLoopSource: inout CFRunLoopSource?,
        owner: String = "event",
        runLoop: CFRunLoop = CFRunLoopGetMain(),
        mode: CFRunLoopMode = .commonModes,
        operations: EventTapTeardownOperations = .live
    ) {
        let currentTap = tap
        let currentSource = runLoopSource

        if let currentTap {
            operations.disableTap(currentTap)
        }
        if let currentSource {
            operations.removeRunLoopSource(runLoop, currentSource, mode)
        }
        if let currentTap {
            operations.invalidateTap(currentTap)
            eventTapTeardownLog.notice("Invalidated \(owner, privacy: .public) event tap")
        }

        runLoopSource = nil
        tap = nil
    }
}
