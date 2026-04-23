// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import OmniWMIPC

enum CLIOutputFormat: String, Equatable {
    case json
    case table
    case tsv
    case text

    var prefersJSON: Bool {
        self == .json
    }

    static func defaultFormat(for command: String?) -> CLIOutputFormat {
        switch command {
        case "query", "subscribe":
            .json
        default:
            .text
        }
    }
}

enum CLILocalAction: Equatable {
    case help
    case completion(CLIShell)
}

enum CLIInvocation: Equatable {
    case remote(IPCRequest)
    case local(CLILocalAction)
}

enum CLIShell: String, CaseIterable, Equatable {
    case zsh
    case bash
    case fish
}
