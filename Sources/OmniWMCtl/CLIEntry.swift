// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Darwin

@main
enum OmniWMCtlMain {
    static func main() async {
        exit(await CLIRuntime.run(arguments: CommandLine.arguments))
    }
}
