// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Darwin
import Foundation
import OmniWMIPC

enum CLIRuntimeOutput {
    static func reportSubscriptionError(_ error: Error, format: CLIOutputFormat) -> Int32 {
        switch error {
        case is CancellationError:
            return CLIExitCode.success.rawValue
        case let error as CLIWatchChild.Failure:
            if Task.isCancelled {
                return CLIExitCode.success.rawValue
            }
            switch error {
            case let .childLaunch(underlying):
                return reportInternalError(underlying, format: format)
            }
        default:
            if Task.isCancelled {
                return CLIExitCode.success.rawValue
            }
            return report(error, format: format)
        }
    }

    static func reportParseError(_ error: CLIParseError, format: CLIOutputFormat) -> Int32 {
        writeLocalFailure(
            try? CLIRenderer.parseErrorOutput(error, format: format),
            outputFormat: format,
            code: .invalidArguments,
            exitCode: .invalidArguments,
            fallbackMessage: CLIParser.usageText
        )
        return CLIExitCode.invalidArguments.rawValue
    }

    static func report(_ error: Error, format: CLIOutputFormat) -> Int32 {
        if isTransportError(error) {
            writeLocalFailure(
                try? CLIRenderer.transportErrorOutput(error, format: format),
                outputFormat: format,
                code: .transportFailure,
                exitCode: .transportFailure,
                fallbackMessage: "omniwmctl: \(error)"
            )
            return CLIExitCode.transportFailure.rawValue
        }
        return reportInternalError(error, format: format)
    }

    static func reportInternalError(_ error: Error, format: CLIOutputFormat) -> Int32 {
        writeLocalFailure(
            try? CLIRenderer.internalErrorOutput(error, format: format),
            outputFormat: format,
            code: .internalError,
            exitCode: .internalError,
            fallbackMessage: "omniwmctl: \(error)"
        )
        return CLIExitCode.internalError.rawValue
    }

    private static func writeLocalFailure(
        _ rendered: CLIRenderedOutput?,
        outputFormat: CLIOutputFormat,
        code: CLILocalErrorCode,
        exitCode: CLIExitCode,
        fallbackMessage: String
    ) {
        if let rendered {
            CLIRenderer.write(rendered)
            return
        }

        if outputFormat.prefersJSON {
            FileHandle.standardOutput.write(
                minimalJSONFailure(code: code, exitCode: exitCode, message: fallbackMessage)
            )
            return
        }

        let text = fallbackMessage.hasSuffix("\n") ? fallbackMessage : fallbackMessage + "\n"
        FileHandle.standardError.write(Data(text.utf8))
    }

    private static func minimalJSONFailure(
        code: CLILocalErrorCode,
        exitCode: CLIExitCode,
        message: String
    ) -> Data {
        let escapedMessage = jsonEscaped(message)
        let json = """
        {
          "code" : "\(code.rawValue)",
          "exitCode" : \(exitCode.rawValue),
          "message" : "\(escapedMessage)",
          "ok" : false,
          "source" : "cli",
          "status" : "error"
        }
        """
        return Data((json + "\n").utf8)
    }

    private static func jsonEscaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    static func isTransportError(_ error: Error) -> Bool {
        if error is POSIXError {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain
    }

    static func writeNotice(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
