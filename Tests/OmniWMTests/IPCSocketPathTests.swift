import Foundation
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
}
