// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct OmniWMStoragePaths: Equatable {
    let configDirectory: URL
    let stateDirectory: URL

    static var live: OmniWMStoragePaths {
        resolve(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    var diagnosticsDirectory: URL {
        stateDirectory.appendingPathComponent("diagnostics", isDirectory: true)
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleIdentifier: String? = nil
    ) -> OmniWMStoragePaths {
        let homeDirectory = homeDirectory.standardizedFileURL
        let directoryName = bundleIdentifier == "com.barut.OmniWM.dev" ? "omniwm-dev" : "omniwm"
        return OmniWMStoragePaths(
            configDirectory: directory(
                environmentKey: "XDG_CONFIG_HOME",
                fallbackBase: homeDirectory.appendingPathComponent(".config", isDirectory: true),
                environment: environment,
                directoryName: directoryName
            ),
            stateDirectory: directory(
                environmentKey: "XDG_STATE_HOME",
                fallbackBase: homeDirectory.appendingPathComponent(".local/state", isDirectory: true),
                environment: environment,
                directoryName: directoryName
            )
        )
    }

    private static func directory(
        environmentKey: String,
        fallbackBase: URL,
        environment: [String: String],
        directoryName: String
    ) -> URL {
        baseDirectory(
            environmentKey: environmentKey,
            fallbackBase: fallbackBase,
            environment: environment
        )
        .appendingPathComponent(directoryName, isDirectory: true)
        .standardizedFileURL
    }

    private static func baseDirectory(
        environmentKey: String,
        fallbackBase: URL,
        environment: [String: String]
    ) -> URL {
        guard let path = environment[environmentKey], path.hasPrefix("/") else {
            return fallbackBase.standardizedFileURL
        }

        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}
