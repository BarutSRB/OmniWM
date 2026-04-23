// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Darwin
import Testing

import OmniWMIPC

@Suite struct IPCSocketPathTests {
    @Test func environmentOverrideWins() {
        let path = "/tmp/omniwm-custom.sock"

        #expect(IPCSocketPath.resolvedPath(environment: [IPCSocketPath.environmentKey: path]) == path)
    }

    @Test func defaultPathUsesOmniWMCachesLocation() {
        let path = IPCSocketPath.resolvedPath(environment: [:], fileManager: .default)

        #expect(path.hasSuffix("/com.barut.OmniWM/ipc.sock"))
    }

    @Test func secretPathLivesBesideSocketPath() {
        #expect(
            IPCSocketPath.secretPath(forSocketPath: "/tmp/omniwm.sock") == "/tmp/omniwm.sock.secret"
        )
    }

    @Test func secretReaderRejectsSymlinkPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omniwm-ipc-secret-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let socketPath = directory.appendingPathComponent("ipc.sock").path
        let secretPath = IPCSocketPath.secretPath(forSocketPath: socketPath)
        let targetPath = directory.appendingPathComponent("target.secret").path
        try "secret".write(toFile: targetPath, atomically: true, encoding: .utf8)
        chmod(targetPath, 0o600)
        symlink(targetPath, secretPath)

        #expect(ZigIPCSupport.readSecretToken(forSocketPath: socketPath) == nil)
    }

    @Test func secretReaderRejectsGroupOrOtherReadableFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omniwm-ipc-secret-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let socketPath = directory.appendingPathComponent("ipc.sock").path
        let secretPath = IPCSocketPath.secretPath(forSocketPath: socketPath)
        try ZigIPCSupport.writeSecretToken("secret", forSocketPath: socketPath)

        chmod(secretPath, 0o644)
        #expect(ZigIPCSupport.readSecretToken(forSocketPath: socketPath) == nil)

        chmod(secretPath, 0o600)
        #expect(ZigIPCSupport.readSecretToken(forSocketPath: socketPath) == "secret")
    }
}
