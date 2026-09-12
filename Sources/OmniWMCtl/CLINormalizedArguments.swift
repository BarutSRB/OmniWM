// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import OmniWMIPC

struct CLINormalizedArguments {
    let arguments: [String]
    let outputFormat: CLIOutputFormat?

    init(arguments: [String]) {
        let rawArguments = Array(arguments.dropFirst())
        let execIndex = rawArguments.firstIndex(of: "--exec") ?? rawArguments.endIndex

        var filteredArguments: [String] = []
        var outputFormat: CLIOutputFormat?
        var index = 0

        while index < rawArguments.count {
            let argument = rawArguments[index]
            if index < execIndex, argument == "--format", index + 1 < rawArguments.count,
               let format = CLIOutputFormat(rawValue: rawArguments[index + 1])
            {
                outputFormat = format
                index += 2
                continue
            }
            if index < execIndex, argument == "--json" {
                outputFormat = .json
                index += 1
                continue
            }

            filteredArguments.append(argument)
            index += 1
        }

        self.arguments = filteredArguments
        self.outputFormat = outputFormat
    }
}
