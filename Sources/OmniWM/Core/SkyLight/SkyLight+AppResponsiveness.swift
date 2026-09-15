// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation

extension SkyLight {
    typealias AppUnresponsiveStatusFunc = @convention(c) (
        Int32,
        UnsafePointer<ProcessSerialNumber>,
        UnsafeMutablePointer<Double>?,
        UnsafeMutablePointer<UInt32>
    ) -> Int32

    private nonisolated static let appResponsivenessFunctions = {
        var resolver = SkyLightSymbolResolver()
        return (
            connection: resolver.resolveOptional(
                "SLSMainConnectionID", as: SkyLightConnectionFunctions.MainConnectionIDFunc.self
            ),
            status: resolver.resolveOptional("SLSEventAppUnresponsiveStatus", as: AppUnresponsiveStatusFunc.self)
        )
    }()

    nonisolated static func isAppUnresponsive(_ pid: pid_t) -> Bool? {
        appUnresponsiveStatus(
            pid,
            mainConnectionID: appResponsivenessFunctions.connection,
            status: appResponsivenessFunctions.status
        )
    }

    nonisolated static func appUnresponsiveStatus(
        _ pid: pid_t,
        mainConnectionID: SkyLightConnectionFunctions.MainConnectionIDFunc?,
        status: AppUnresponsiveStatusFunc?,
        processForPID: (pid_t, inout ProcessSerialNumber) -> OSStatus = getProcessForPID
    ) -> Bool? {
        guard let mainConnectionID, let status else { return nil }
        var psn = ProcessSerialNumber()
        guard processForPID(pid, &psn) == noErr else { return nil }
        let connectionID = mainConnectionID()
        guard connectionID != 0 else { return nil }
        var flags: UInt32 = 0
        guard status(connectionID, &psn, nil, &flags) == 0 else { return nil }
        return flags & 2 != 0
    }
}
