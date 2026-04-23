// SPDX-License-Identifier: GPL-2.0-only
import Foundation

public enum IPCSocketPath {
    public static let environmentKey = "OMNIWM_SOCKET"
    public static let secretSuffix = ".secret"

    public static func resolvedPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String {
        _ = fileManager
        return ZigIPCSupport.resolvedSocketPath(overridePath: environment[environmentKey])
    }

    public static func secretPath(forSocketPath socketPath: String) -> String {
        ZigIPCSupport.secretPath(forSocketPath: socketPath)
    }

    public static func resolvedSecretPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String {
        secretPath(forSocketPath: resolvedPath(environment: environment, fileManager: fileManager))
    }
}
