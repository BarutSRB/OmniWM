// SPDX-License-Identifier: GPL-2.0-only
import Darwin

@main
enum OmniWMCtlMain {
    static func main() async {
        exit(await CLIRuntime.run(arguments: CommandLine.arguments))
    }
}
