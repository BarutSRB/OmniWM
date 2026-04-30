// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation
import Testing

import OmniWMIPC
@testable import OmniWM
@testable import OmniWMCtl

private let ipcServerTestSessionToken = "ipc-server-tests"

private func makeIPCTestSocketPath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("omniwm-ipc-\(UUID().uuidString).sock")
        .path
}

private func makeIPCTestSocketAddress(for path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)

    let utf8Path = Array(path.utf8)
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    guard utf8Path.count < pathCapacity else {
        throw POSIXError(.ENAMETOOLONG)
    }

    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        for (index, byte) in utf8Path.enumerated() {
            buffer[index] = byte
        }
    }

    return address
}

private func createStaleSocketFile(at path: String) throws {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw POSIXError(.EIO)
    }
    defer { close(fd) }

    var address = try makeIPCTestSocketAddress(for: path)
    let bindResult = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
            bind(fd, pointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    guard bindResult == 0 else {
        let error = POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE
        throw POSIXError(error)
    }
}

private func socketMode(at path: String) throws -> mode_t {
    var fileStatus = stat()
    guard lstat(path, &fileStatus) == 0 else {
        let error = POSIXErrorCode(rawValue: errno) ?? .EIO
        throw POSIXError(error)
    }
    return fileStatus.st_mode
}

private func openRawIPCTestConnection(to path: String) throws -> FileHandle {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw POSIXError(.EIO)
    }

    var noSigPipe: Int32 = 1
    _ = withUnsafePointer(to: &noSigPipe) { pointer in
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            pointer,
            socklen_t(MemoryLayout<Int32>.size)
        )
    }

    var address = try makeIPCTestSocketAddress(for: path)
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
            connect(fd, pointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    guard result == 0 else {
        let error = POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED
        close(fd)
        throw POSIXError(error)
    }

    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
}

private func readRawLine(from handle: FileHandle) throws -> Data? {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)

    while true {
        if let newlineIndex = buffer.firstIndex(of: 0x0A) {
            return Data(buffer.prefix(upTo: newlineIndex))
        }

        let count = Darwin.read(handle.fileDescriptor, &chunk, chunk.count)
        if count > 0 {
            buffer.append(contentsOf: chunk[0..<count])
            continue
        }
        if count == 0 {
            return buffer.isEmpty ? nil : buffer
        }
        if errno == EINTR {
            continue
        }

        let error = POSIXErrorCode(rawValue: errno) ?? .EIO
        throw POSIXError(error)
    }
}

private func makeTestFocusEvent(id: String, title: String) -> IPCEventEnvelope {
    IPCEventEnvelope.success(
        id: id,
        channel: .focus,
        result: IPCResult(
            focusedWindow: IPCFocusedWindowQueryResult(
                window: IPCFocusedWindowSnapshot(
                    id: "ow_\(id)",
                    workspace: IPCWorkspaceRef(id: "ws-1", rawName: "1", displayName: "One", number: 1),
                    display: IPCDisplayRef(id: "display:1", name: "Main", isMain: true),
                    app: IPCAppRef(name: "Focus App", bundleId: "com.example.focus"),
                    title: title,
                    frame: nil
                )
            )
        )
    )
}

@Suite(.serialized) @MainActor struct IPCServerTests {
    @Test func serverCleansStaleSocketAndServesPingAndVersion() async throws {
        let socketPath = makeIPCTestSocketPath()
        let secretPath = IPCSocketPath.secretPath(forSocketPath: socketPath)
        try createStaleSocketFile(at: socketPath)

        let controller = makeLayoutPlanTestController()
        let server = IPCServer(
            controller: controller,
            socketPath: socketPath,
            versionProvider: { "9.9.9" },
            sessionToken: ipcServerTestSessionToken
        )
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        try server.start()

        let mode = try socketMode(at: socketPath)
        #expect(mode & S_IFMT == S_IFSOCK)
        #expect(mode & 0o777 == 0o600)
        let secretMode = try socketMode(at: secretPath)
        #expect(secretMode & 0o777 == 0o600)

        let client = IPCClient(socketPath: socketPath)
        let pingConnection = try client.openConnection()
        defer {
            Task {
                await pingConnection.close()
            }
        }

        try await pingConnection.send(IPCRequest(id: "ping-1", kind: .ping))
        let pingResponse = try await pingConnection.readResponse()
        #expect(pingResponse.ok)
        #expect(pingResponse.kind == .ping)
        #expect(pingResponse.result?.kind == .pong)

        let versionConnection = try client.openConnection()
        defer {
            Task {
                await versionConnection.close()
            }
        }

        try await versionConnection.send(IPCRequest(id: "version-1", kind: .version))
        let versionResponse = try await versionConnection.readResponse()
        #expect(versionResponse.ok)
        #expect(versionResponse.kind == .version)
        #expect(versionResponse.result?.kind == .version)
        if case let .version(version)? = versionResponse.result?.payload {
            #expect(version.appVersion == "9.9.9")
        } else {
            Issue.record("Expected version payload")
        }
    }

    @Test func serverRejectsRequestsWithoutSessionSecret() async throws {
        let socketPath = makeIPCTestSocketPath()
        let controller = makeLayoutPlanTestController()
        let server = IPCServer(controller: controller, socketPath: socketPath)
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(atPath: IPCSocketPath.secretPath(forSocketPath: socketPath))
        }
        try server.start()

        let connection = try openRawIPCTestConnection(to: socketPath)
        defer { try? connection.close() }

        try connection.write(contentsOf: IPCWire.encodeRequestLine(IPCRequest(id: "unauth", kind: .ping)))
        let line = try #require(try readRawLine(from: connection))
        let response = try IPCWire.decodeResponse(from: line)

        #expect(response.ok == false)
        #expect(response.code == .unauthorized)
    }

    @Test func bridgeRejectsAuthorizedRequestsAfterShutdownStarts() async {
        let controller = makeLayoutPlanTestController()
        let bridge = IPCApplicationBridge(
            controller: controller,
            appVersion: nil,
            sessionToken: ipcServerTestSessionToken,
            authorizationToken: "bridge-shutdown-token"
        )

        bridge.beginShutdown()

        let unauthorized = await bridge.response(for: IPCRequest(id: "unauth-after-stop", kind: .ping))
        #expect(unauthorized.ok == false)
        #expect(unauthorized.code == .unauthorized)

        let authorized = await bridge.response(
            for: IPCRequest(
                id: "command-after-stop",
                command: .focus(direction: .left),
                authorizationToken: "bridge-shutdown-token"
            )
        )
        #expect(authorized.ok == false)
        #expect(authorized.status == .ignored)
        #expect(authorized.code == .disabled)
        #expect(authorized.kind == .command)

        let rule = await bridge.response(
            for: IPCRequest(
                id: "rule-after-stop",
                rule: .add(rule: IPCRuleDefinition(bundleId: "com.example.app")),
                authorizationToken: "bridge-shutdown-token"
            )
        )
        #expect(rule.ok == false)
        #expect(rule.status == .ignored)
        #expect(rule.code == .disabled)
        #expect(rule.kind == .rule)
    }

    @Test func serverUnlinksSocketOnStop() throws {
        let socketPath = makeIPCTestSocketPath()
        let controller = makeLayoutPlanTestController()
        let server = IPCServer(controller: controller, socketPath: socketPath)
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        try server.start()
        #expect(FileManager.default.fileExists(atPath: socketPath))

        server.stop()

        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    @Test func serverRejectsNonSocketPathsInsteadOfDeletingThem() {
        let socketPath = makeIPCTestSocketPath()
        FileManager.default.createFile(atPath: socketPath, contents: Data("not-a-socket".utf8))
        defer {
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let controller = makeLayoutPlanTestController()
        let server = IPCServer(controller: controller, socketPath: socketPath)

        do {
            try server.start()
            Issue.record("Expected server start to fail for a non-socket path")
        } catch let error as POSIXError {
            #expect(error.code == .EEXIST)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func serverDoesNotReplaceAnActiveSocketListener() async throws {
        let socketPath = makeIPCTestSocketPath()
        let firstController = makeLayoutPlanTestController()
        let firstServer = IPCServer(controller: firstController, socketPath: socketPath)
        try firstServer.start()
        defer {
            firstServer.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let secondController = makeLayoutPlanTestController()
        let secondServer = IPCServer(controller: secondController, socketPath: socketPath)

        do {
            try secondServer.start()
            Issue.record("Expected the second server to fail while the first listener is active")
        } catch let error as POSIXError {
            #expect(error.code == .EADDRINUSE)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let client = IPCClient(socketPath: socketPath)
        let connection = try client.openConnection()
        defer {
            Task {
                await connection.close()
            }
        }

        try await connection.send(IPCRequest(id: "still-live", kind: .ping))
        let response = try await connection.readResponse()
        #expect(response.ok)
        #expect(response.result?.kind == .pong)
    }

    @Test func clientUsesResolvedEnvironmentSocketOverridePath() async throws {
        let socketPath = makeIPCTestSocketPath()
        let controller = makeLayoutPlanTestController()
        let server = IPCServer(controller: controller, socketPath: socketPath)
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        try server.start()

        let client = IPCClient(
            socketPath: IPCSocketPath.resolvedPath(environment: [IPCSocketPath.environmentKey: socketPath])
        )
        let connection = try client.openConnection()
        defer {
            Task {
                await connection.close()
            }
        }

        try await connection.send(IPCRequest(id: "env-1", kind: .ping))
        let response = try await connection.readResponse()

        #expect(response.ok)
        #expect(response.result?.kind == .pong)
    }

    @Test func clientCanReconnectAfterServerRestart() async throws {
        let socketPath = makeIPCTestSocketPath()
        let controller = makeLayoutPlanTestController()

        let firstServer = IPCServer(controller: controller, socketPath: socketPath)
        try firstServer.start()

        do {
            let client = IPCClient(socketPath: socketPath)
            let firstConnection = try client.openConnection()
            defer {
                Task {
                    await firstConnection.close()
                }
            }

            try await firstConnection.send(IPCRequest(id: "restart-1", kind: .ping))
            let response = try await firstConnection.readResponse()
            #expect(response.ok)
        }

        firstServer.stop()

        let secondServer = IPCServer(controller: controller, socketPath: socketPath)
        defer {
            secondServer.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        try secondServer.start()

        let client = IPCClient(socketPath: socketPath)
        let secondConnection = try client.openConnection()
        defer {
            Task {
                await secondConnection.close()
            }
        }

        try await secondConnection.send(IPCRequest(id: "restart-2", kind: .version))
        let response = try await secondConnection.readResponse()

        #expect(response.ok)
        #expect(response.result?.kind == .version)
    }

    @Test func versionRequestSucceedsEvenWhenProtocolVersionDiffers() async throws {
        let socketPath = makeIPCTestSocketPath()
        let controller = makeLayoutPlanTestController()
        let server = IPCServer(
            controller: controller,
            socketPath: socketPath,
            versionProvider: { "1.2.3" }
        )
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        try server.start()

        let client = IPCClient(socketPath: socketPath)
        let connection = try client.openConnection()
        defer {
            Task { await connection.close() }
        }

        try await connection.send(
            IPCRequest(
                version: OmniWMIPCProtocol.version - 1,
                id: "version-mismatch",
                kind: .version,
                payload: .none(.init())
            )
        )
        let response = try await connection.readResponse()

        #expect(response.ok)
        #expect(response.kind == .version)
        if case let .version(version)? = response.result?.payload {
            #expect(version.protocolVersion == OmniWMIPCProtocol.version)
            #expect(version.appVersion == "1.2.3")
        } else {
            Issue.record("Expected version payload")
        }
    }

    @Test func nonVersionProtocolMismatchReturnsRecoverableVersionPayload() async throws {
        let socketPath = makeIPCTestSocketPath()
        let controller = makeLayoutPlanTestController()
        let server = IPCServer(
            controller: controller,
            socketPath: socketPath,
            versionProvider: { "1.2.3" }
        )
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        try server.start()

        let client = IPCClient(socketPath: socketPath)
        let connection = try client.openConnection()
        defer {
            Task { await connection.close() }
        }

        try await connection.send(
            IPCRequest(
                version: OmniWMIPCProtocol.version - 1,
                id: "query-mismatch",
                kind: .query,
                payload: .query(IPCQueryRequest(name: .apps))
            )
        )
        let response = try await connection.readResponse()

        #expect(response.ok == false)
        #expect(response.kind == .query)
        #expect(response.code == .protocolMismatch)
        if case let .version(version)? = response.result?.payload {
            #expect(version.protocolVersion == OmniWMIPCProtocol.version)
            #expect(version.appVersion == "1.2.3")
        } else {
            Issue.record("Expected recovery version payload")
        }
    }

    @Test func staleRawWorkspaceNameOnlyRequestReturnsInvalidRequestBeforeVersionHandshake() async throws {
        let socketPath = makeIPCTestSocketPath()
        let controller = makeLayoutPlanTestController()
        let initialWorkspaceName = try #require(controller.activeWorkspace()?.name)
        let server = IPCServer(controller: controller, socketPath: socketPath)
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        try server.start()

        let connection = try openRawIPCTestConnection(to: socketPath)
        defer { try? connection.close() }

        // v4 was the last protocol version that decoded bare `workspaceName` payloads.
        let retiredWorkspaceNamePayloadProtocolVersion = 4
        let rawRequest = """
        {
          "version": \(retiredWorkspaceNamePayloadProtocolVersion),
          "id": "legacy-workspace",
          "kind": "workspace",
          "payload": {
            "name": "focus-name",
            "workspaceName": "2"
          }
        }
        """

        try connection.write(contentsOf: Data((rawRequest + "\n").utf8))
        let line = try #require(try readRawLine(from: connection))
        let response = try IPCWire.decodeResponse(from: line)

        #expect(response.ok == false)
        #expect(response.id == "")
        #expect(response.kind == .error)
        #expect(response.code == .invalidRequest)
        #expect(controller.activeWorkspace()?.name == initialWorkspaceName)
    }

    @Test func disabledMutationsStillReturnClearQueries() async throws {
        let socketPath = makeIPCTestSocketPath()
        let controller = makeLayoutPlanTestController()
        controller.isEnabled = false

        let server = IPCServer(controller: controller, socketPath: socketPath)
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        try server.start()

        let client = IPCClient(socketPath: socketPath)

        let commandConnection = try client.openConnection()
        defer {
            Task {
                await commandConnection.close()
            }
        }
        try await commandConnection.send(
            IPCRequest(
                id: "cmd-1",
                command: .focus(direction: .left)
            )
        )
        let commandResponse = try await commandConnection.readResponse()
        #expect(commandResponse.ok == false)
        #expect(commandResponse.kind == .command)
        #expect(commandResponse.status == .ignored)
        #expect(commandResponse.code == .disabled)

        let queryConnection = try client.openConnection()
        defer {
            Task {
                await queryConnection.close()
            }
        }
        try await queryConnection.send(
            IPCRequest(
                id: "query-1",
                query: IPCQueryRequest(name: .apps)
            )
        )
        let queryResponse = try await queryConnection.readResponse()
        #expect(queryResponse.ok)
        #expect(queryResponse.kind == .query)
        #expect(queryResponse.result?.kind == .apps)
    }

    @Test func windowsQueryReturnsCanonicalNestedFields() async throws {
        let socketPath = makeIPCTestSocketPath()
        let controller = makeLayoutPlanTestController()
        let workspaceId = try #require(controller.workspaceManager.workspaceId(for: "1", createIfMissing: false))
        controller.appInfoCache.storeInfoForTests(pid: 9051, name: "Terminal", bundleId: "com.example.terminal")
        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 12001),
            pid: 9051,
            windowId: 12001,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId)

        let server = IPCServer(
            controller: controller,
            socketPath: socketPath,
            sessionToken: ipcServerTestSessionToken
        )
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        try server.start()

        let client = IPCClient(socketPath: socketPath)
        let connection = try client.openConnection()
        defer {
            Task { await connection.close() }
        }

        try await connection.send(
            IPCRequest(
                id: "query-windows-canonical",
                query: IPCQueryRequest(
                    name: .windows,
                    fields: ["id", "workspace", "display", "app"]
                )
            )
        )
        let response = try await connection.readResponse()

        #expect(response.ok)
        if case let .windows(payload)? = response.result?.payload {
            #expect(payload.windows.count == 1)
            #expect(payload.windows.first?.id == IPCWindowOpaqueID.encode(
                pid: token.pid,
                windowId: token.windowId,
                sessionToken: ipcServerTestSessionToken
            ))
            #expect(payload.windows.first?.workspace?.rawName == "1")
            #expect(payload.windows.first?.display?.id == "display:\(layoutPlanTestMainDisplayId())")
            #expect(payload.windows.first?.app?.bundleId == "com.example.terminal")
        } else {
            Issue.record("Expected windows payload")
        }
    }

    @Test func queriedOpaqueWindowIdCanBeFedBackIntoRuleApplyWithoutLeakingRawTokens() async throws {
        let socketPath = makeIPCTestSocketPath()
        let controller = makeLayoutPlanTestController()
        let workspaceId = try #require(controller.workspaceManager.workspaceId(for: "1", createIfMissing: false))
        controller.appInfoCache.storeInfoForTests(
            pid: 9052,
            name: "Rule Apply App",
            bundleId: "com.example.rule-apply"
        )
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onFullRescan = { _ in true }
        let token = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 12002),
            pid: 9052,
            windowId: 12002,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(token, in: workspaceId)
        controller.settings.appRules = [AppRule(bundleId: "com.example.rule-apply", layout: .float)]
        controller.updateAppRules()
        await waitForLayoutPlanRefreshWork(on: controller)
        #expect(controller.workspaceManager.entry(for: token)?.mode == .tiling)

        let server = IPCServer(
            controller: controller,
            socketPath: socketPath,
            sessionToken: ipcServerTestSessionToken
        )
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        try server.start()

        let client = IPCClient(socketPath: socketPath)
        let connection = try client.openConnection()
        defer {
            Task { await connection.close() }
        }

        try await connection.send(
            IPCRequest(
                id: "query-window-id",
                query: IPCQueryRequest(name: .windows, fields: ["id"])
            )
        )
        let queryResponse = try await connection.readResponse()
        #expect(queryResponse.ok)

        guard case let .windows(payload)? = queryResponse.result?.payload else {
            Issue.record("Expected windows payload")
            return
        }
        let opaqueWindowId = try #require(payload.windows.first?.id)
        #expect(opaqueWindowId != "\(token.pid):\(token.windowId)")
        let decodedWindowId = IPCWindowOpaqueID.decode(
            opaqueWindowId,
            expectingSessionToken: ipcServerTestSessionToken
        )
        #expect(decodedWindowId?.pid == token.pid)
        #expect(decodedWindowId?.windowId == token.windowId)

        try await connection.send(
            IPCRequest(
                id: "apply-window-id",
                rule: .apply(target: .window(windowId: opaqueWindowId))
            )
        )
        let applyResponse = try await connection.readResponse()

        #expect(applyResponse.ok)
        #expect(applyResponse.kind == .rule)
        #expect(controller.workspaceManager.entry(for: token)?.mode == .floating)
        if case let .rules(rules)? = applyResponse.result?.payload {
            #expect(rules.rules.first?.bundleId == "com.example.rule-apply")
        } else {
            Issue.record("Expected rules payload")
        }
    }

    @Test func queryValidationRejectsUnsupportedFieldsAndSelectors() async throws {
        let socketPath = makeIPCTestSocketPath()
        let controller = makeLayoutPlanTestController()
        let server = IPCServer(controller: controller, socketPath: socketPath)
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        try server.start()

        let client = IPCClient(socketPath: socketPath)
        let connection = try client.openConnection()
        defer {
            Task { await connection.close() }
        }

        try await connection.send(
            IPCRequest(
                id: "bad-field",
                query: IPCQueryRequest(name: .windows, fields: ["workspace-id"])
            )
        )
        let badFieldResponse = try await connection.readResponse()
        #expect(badFieldResponse.ok == false)
        #expect(badFieldResponse.code == .invalidArguments)

        try await connection.send(
            IPCRequest(
                id: "bad-selector",
                query: IPCQueryRequest(name: .workspaces, selectors: IPCQuerySelectors(main: true))
            )
        )
        let badSelectorResponse = try await connection.readResponse()
        #expect(badSelectorResponse.ok == false)
        #expect(badSelectorResponse.code == .invalidArguments)
    }

    @Test func queryValidationRejectsInvalidAndStaleWindowSelectors() async throws {
        let socketPath = makeIPCTestSocketPath()
        let controller = makeLayoutPlanTestController()
        let server = IPCServer(
            controller: controller,
            socketPath: socketPath,
            sessionToken: ipcServerTestSessionToken
        )
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        try server.start()

        let client = IPCClient(socketPath: socketPath)
        let connection = try client.openConnection()
        defer {
            Task { await connection.close() }
        }

        try await connection.send(
            IPCRequest(
                id: "invalid-window-selector",
                query: IPCQueryRequest(name: .windows, selectors: IPCQuerySelectors(window: "ow_not-valid"))
            )
        )
        let invalidResponse = try await connection.readResponse()
        #expect(invalidResponse.ok == false)
        #expect(invalidResponse.code == .invalidArguments)

        try await connection.send(
            IPCRequest(
                id: "stale-window-selector",
                query: IPCQueryRequest(
                    name: .windows,
                    selectors: IPCQuerySelectors(
                        window: IPCWindowOpaqueID.encode(pid: 7, windowId: 9, sessionToken: "other-session")
                    )
                )
            )
        )
        let staleResponse = try await connection.readResponse()
        #expect(staleResponse.ok == false)
        #expect(staleResponse.code == .staleWindowId)
    }

    @Test func oversizedRequestReturnsInvalidRequestAndClosesConnection() async throws {
        let socketPath = makeIPCTestSocketPath()
        let controller = makeLayoutPlanTestController()
        let server = IPCServer(controller: controller, socketPath: socketPath)
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        try server.start()

        let connection = try openRawIPCTestConnection(to: socketPath)
        defer { try? connection.close() }

        let oversizedRequest = Data(repeating: 0x61, count: IPCConnection.maxRequestLineBytes + 1)
        try connection.write(contentsOf: oversizedRequest)

        let line = try #require(try readRawLine(from: connection))
        let response = try IPCWire.decodeResponse(from: line)

        #expect(response.ok == false)
        #expect(response.kind == .error)
        #expect(response.code == .invalidRequest)
        #expect(try readRawLine(from: connection) == nil)
    }

    @Test func focusSubscriptionStreamsNDJSONEventsFromRealFocusChanges() async throws {
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        defer { axHooksLease.release() }

        let socketPath = makeIPCTestSocketPath()
        let controller = makeLayoutPlanTestController()
        defer {
            AXWindowService.titleLookupProviderForTests = nil
            resetSharedControllerStateForTests()
        }

        let workspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false)!
        controller.appInfoCache.storeInfoForTests(pid: 9101, name: "Terminal", bundleId: "com.example.terminal")
        controller.appInfoCache.storeInfoForTests(pid: 9102, name: "Browser", bundleId: "com.example.browser")
        AXWindowService.titleLookupProviderForTests = { windowId in
            switch windowId {
            case 1301:
                "Initial Focus"
            case 1302:
                "Focused Event Window"
            default:
                nil
            }
        }
        let initialToken = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1301),
            pid: 9101,
            windowId: 1301,
            to: workspaceId
        )
        let updatedToken = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1302),
            pid: 9102,
            windowId: 1302,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(initialToken, in: workspaceId)

        let server = IPCServer(
            controller: controller,
            socketPath: socketPath,
            sessionToken: ipcServerTestSessionToken
        )
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        try server.start()

        let client = IPCClient(socketPath: socketPath)
        let connection = try client.openConnection()
        defer {
            Task {
                await connection.close()
            }
        }

        try await connection.send(
            IPCRequest(
                id: "sub-1",
                subscribe: IPCSubscribeRequest(channels: [.focus])
            )
        )
        let subscribeResponse = try await connection.readResponse()
        #expect(subscribeResponse.ok)
        #expect(subscribeResponse.kind == .subscribe)
        #expect(subscribeResponse.status == .subscribed)

        let events = await connection.eventStream()
        var iterator = events.makeAsyncIterator()
        let initialNextEvent = try await iterator.next()
        let initialEvent = try #require(initialNextEvent)
        #expect(initialEvent.channel == .focus)
        if case let .focusedWindow(payload) = initialEvent.result.payload {
            #expect(payload.window?.title == "Initial Focus")
        } else {
            Issue.record("Expected focused-window initial payload")
        }

        _ = controller.workspaceManager.setManagedFocus(updatedToken, in: workspaceId)

        let nextEvent = try await iterator.next()
        let event = try #require(nextEvent)
        #expect(event.channel == .focus)
        #expect(event.ok)
        #expect(event.status == .success)
        #expect(!event.id.isEmpty)
        if case let .focusedWindow(payload) = event.result.payload {
            #expect(payload.window?.title == "Focused Event Window")
            #expect(
                payload.window?.id == IPCWindowOpaqueID.encode(
                    pid: updatedToken.pid,
                    windowId: updatedToken.windowId,
                    sessionToken: ipcServerTestSessionToken
                )
            )
        } else {
            Issue.record("Expected focused-window event payload")
        }
    }

    @Test func focusSubscriptionBuffersLiveEventPublishedAfterResponseWhenInitialSnapshotIsDisabled() async throws {
        let socketPath = makeIPCTestSocketPath()
        let controller = makeLayoutPlanTestController()

        let server = IPCServer(
            controller: controller,
            socketPath: socketPath,
            sessionToken: ipcServerTestSessionToken
        )
        defer {
            server.stop()
            IPCConnection.setSubscriptionTestHooksForTests(nil)
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        try server.start()

        let bridge = try #require(controller.ipcApplicationBridge)
        let bufferedEvent = makeTestFocusEvent(id: "evt-gap", title: "Buffered Focus Event")
        IPCConnection.setSubscriptionTestHooksForTests(
            .init(
                afterSubscribeResponseBeforeEventDelivery: {
                    await bridge.publishEventEnvelopeForTests(bufferedEvent)
                }
            )
        )

        let client = IPCClient(socketPath: socketPath)
        let connection = try client.openConnection()
        defer {
            Task {
                await connection.close()
            }
        }

        try await connection.send(
            IPCRequest(
                id: "sub-focus-no-initial-buffered",
                subscribe: IPCSubscribeRequest(
                    channels: [.focus],
                    sendInitial: false
                )
            )
        )

        let subscribeResponse = try await connection.readResponse()
        #expect(subscribeResponse.ok)
        #expect(subscribeResponse.kind == .subscribe)
        #expect(subscribeResponse.status == .subscribed)

        let nextEvent = try await connection.readEvent()
        let event = try #require(nextEvent)
        #expect(event.channel == .focus)
        #expect(event.id == bufferedEvent.id)
        if case let .focusedWindow(payload) = event.result.payload {
            #expect(payload.window?.title == "Buffered Focus Event")
        } else {
            Issue.record("Expected buffered focused-window payload")
        }
    }

    @Test func focusSubscriptionDeliversInitialSnapshotBeforeBufferedLiveEvent() async throws {
        let axHooksLease = await acquireAXTestHooksLeaseForTests()
        defer { axHooksLease.release() }

        let socketPath = makeIPCTestSocketPath()
        let controller = makeLayoutPlanTestController()
        defer {
            AXWindowService.titleLookupProviderForTests = nil
            IPCConnection.setSubscriptionTestHooksForTests(nil)
            resetSharedControllerStateForTests()
        }

        let workspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false)!
        controller.appInfoCache.storeInfoForTests(pid: 9111, name: "Terminal", bundleId: "com.example.terminal")
        AXWindowService.titleLookupProviderForTests = { windowId in
            switch windowId {
            case 1311:
                "Initial Focus"
            default:
                nil
            }
        }
        let initialToken = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1311),
            pid: 9111,
            windowId: 1311,
            to: workspaceId
        )
        _ = controller.workspaceManager.setManagedFocus(initialToken, in: workspaceId)

        let server = IPCServer(
            controller: controller,
            socketPath: socketPath,
            sessionToken: ipcServerTestSessionToken
        )
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        try server.start()

        let bridge = try #require(controller.ipcApplicationBridge)
        let bufferedEvent = makeTestFocusEvent(id: "evt-live", title: "Buffered Live Focus")
        IPCConnection.setSubscriptionTestHooksForTests(
            .init(
                afterSubscribeResponseBeforeEventDelivery: {
                    await bridge.publishEventEnvelopeForTests(bufferedEvent)
                }
            )
        )

        let client = IPCClient(socketPath: socketPath)
        let connection = try client.openConnection()
        defer {
            Task {
                await connection.close()
            }
        }

        try await connection.send(
            IPCRequest(
                id: "sub-focus-buffered-ordering",
                subscribe: IPCSubscribeRequest(channels: [.focus])
            )
        )

        let subscribeResponse = try await connection.readResponse()
        #expect(subscribeResponse.ok)
        #expect(subscribeResponse.kind == .subscribe)
        #expect(subscribeResponse.status == .subscribed)

        let initialNextEvent = try await connection.readEvent()
        let initialEvent = try #require(initialNextEvent)
        #expect(initialEvent.channel == .focus)
        if case let .focusedWindow(payload) = initialEvent.result.payload {
            #expect(payload.window?.title == "Initial Focus")
        } else {
            Issue.record("Expected initial focused-window payload")
        }

        let liveNextEvent = try await connection.readEvent()
        let liveEvent = try #require(liveNextEvent)
        #expect(liveEvent.channel == .focus)
        #expect(liveEvent.id == bufferedEvent.id)
        if case let .focusedWindow(payload) = liveEvent.result.payload {
            #expect(payload.window?.title == "Buffered Live Focus")
        } else {
            Issue.record("Expected buffered live focused-window payload")
        }
    }

    @Test func focusedMonitorSubscriptionStreamsInitialSnapshotAndMonitorChanges() async throws {
        let socketPath = makeIPCTestSocketPath()
        let fixture = makeTwoMonitorLayoutPlanTestController()

        let server = IPCServer(
            controller: fixture.controller,
            socketPath: socketPath,
            sessionToken: ipcServerTestSessionToken
        )
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        try server.start()

        let client = IPCClient(socketPath: socketPath)
        let connection = try client.openConnection()
        defer {
            Task {
                await connection.close()
            }
        }

        try await connection.send(
            IPCRequest(
                id: "sub-focused-monitor",
                subscribe: IPCSubscribeRequest(channels: [.focusedMonitor])
            )
        )
        let subscribeResponse = try await connection.readResponse()
        #expect(subscribeResponse.ok)
        #expect(subscribeResponse.kind == .subscribe)
        #expect(subscribeResponse.status == .subscribed)

        let initialNextEvent = try await connection.readEvent()
        let initialEvent = try #require(initialNextEvent)
        #expect(initialEvent.channel == .focusedMonitor)
        if case let .focusedMonitor(payload) = initialEvent.result.payload {
            #expect(payload.display?.id == "display:\(fixture.primaryMonitor.displayId)")
            #expect(payload.activeWorkspace?.rawName == "1")
        } else {
            Issue.record("Expected focused-monitor initial payload")
        }

        fixture.controller.workspaceNavigationHandler.focusMonitorCyclic(previous: false)

        let nextEvent = try await connection.readEvent()
        let event = try #require(nextEvent)
        #expect(event.channel == .focusedMonitor)
        if case let .focusedMonitor(payload) = event.result.payload {
            #expect(payload.display?.id == "display:\(fixture.secondaryMonitor.displayId)")
            #expect(payload.activeWorkspace?.rawName == "2")
        } else {
            Issue.record("Expected focused-monitor event payload")
        }
    }

    @Test func focusedMonitorSubscriptionHonorsNoSendInitialAndWorkspaceChangesStayOnActiveWorkspaceChannel() async throws {
        let socketPath = makeIPCTestSocketPath()
        let controller = makeLayoutPlanTestController()
        let monitor = try #require(controller.workspaceManager.monitors.first)

        let server = IPCServer(
            controller: controller,
            socketPath: socketPath,
            sessionToken: ipcServerTestSessionToken
        )
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        try server.start()

        let client = IPCClient(socketPath: socketPath)
        let connection = try client.openConnection()
        defer {
            Task {
                await connection.close()
            }
        }

        try await connection.send(
            IPCRequest(
                id: "sub-focused-monitor-no-initial",
                subscribe: IPCSubscribeRequest(
                    channels: [.focusedMonitor, .activeWorkspace],
                    sendInitial: false
                )
            )
        )
        let subscribeResponse = try await connection.readResponse()
        #expect(subscribeResponse.ok)
        #expect(subscribeResponse.status == .subscribed)
        #expect(try await connection.hasPendingData(timeoutMilliseconds: 150) == false)

        let workspaceId = try #require(controller.workspaceManager.workspaceId(for: "2", createIfMissing: false))
        #expect(controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitor.id))

        let firstNextEvent = try await connection.readEvent()
        let firstEvent = try #require(firstNextEvent)
        #expect(firstEvent.channel == .activeWorkspace)
        if case let .activeWorkspace(payload) = firstEvent.result.payload {
            #expect(payload.workspace?.rawName == "2")
        } else {
            Issue.record("Expected active-workspace payload")
        }

        #expect(try await connection.hasPendingData(timeoutMilliseconds: 150) == false)
    }

    @Test func monitorChangesStillPublishActiveWorkspaceAndDisplayChangedEvents() async throws {
        let socketPath = makeIPCTestSocketPath()
        let fixture = makeTwoMonitorLayoutPlanTestController()

        let server = IPCServer(
            controller: fixture.controller,
            socketPath: socketPath,
            sessionToken: ipcServerTestSessionToken
        )
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        try server.start()

        let client = IPCClient(socketPath: socketPath)
        let connection = try client.openConnection()
        defer {
            Task {
                await connection.close()
            }
        }

        try await connection.send(
            IPCRequest(
                id: "sub-monitor-change-suite",
                subscribe: IPCSubscribeRequest(
                    channels: [.activeWorkspace, .focusedMonitor, .displayChanged],
                    sendInitial: false
                )
            )
        )
        let subscribeResponse = try await connection.readResponse()
        #expect(subscribeResponse.ok)

        fixture.controller.workspaceNavigationHandler.focusMonitorCyclic(previous: false)

        let firstNextEvent = try await connection.readEvent()
        let firstEvent = try #require(firstNextEvent)
        let secondNextEvent = try await connection.readEvent()
        let secondEvent = try #require(secondNextEvent)
        let thirdNextEvent = try await connection.readEvent()
        let thirdEvent = try #require(thirdNextEvent)

        #expect([firstEvent.channel, secondEvent.channel, thirdEvent.channel] == [
            .activeWorkspace,
            .focusedMonitor,
            .displayChanged
        ])

        if case let .activeWorkspace(payload) = firstEvent.result.payload {
            #expect(payload.display?.id == "display:\(fixture.secondaryMonitor.displayId)")
            #expect(payload.workspace?.rawName == "2")
        } else {
            Issue.record("Expected active-workspace event payload")
        }

        if case let .focusedMonitor(payload) = secondEvent.result.payload {
            #expect(payload.display?.id == "display:\(fixture.secondaryMonitor.displayId)")
        } else {
            Issue.record("Expected focused-monitor event payload")
        }

        if case let .displays(payload) = thirdEvent.result.payload {
            #expect(payload.displays.contains { $0.id == "display:\(fixture.secondaryMonitor.displayId)" && $0.isCurrent == true })
        } else {
            Issue.record("Expected displays event payload")
        }
    }

    @Test func workspaceBarSubscriptionDeduplicatesChannelsAndStreamsCoalescedRefreshEvents() async throws {
        let socketPath = makeIPCTestSocketPath()
        let controller = makeLayoutPlanTestController()
        controller.configureWorkspaceBarManagerForTests(monitors: controller.workspaceManager.monitors)
        controller.resetWorkspaceBarRefreshDebugStateForTests()
        let workspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false)!
        controller.appInfoCache.storeInfoForTests(pid: 9201, name: "Terminal", bundleId: "com.example.terminal")
        _ = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1401),
            pid: 9201,
            windowId: 1401,
            to: workspaceId
        )

        let server = IPCServer(
            controller: controller,
            socketPath: socketPath,
            sessionToken: ipcServerTestSessionToken
        )
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        try server.start()

        let client = IPCClient(socketPath: socketPath)
        let connection = try client.openConnection()
        defer {
            Task {
                await connection.close()
            }
        }

        try await connection.send(
            IPCRequest(
                id: "sub-workspace-bar",
                subscribe: IPCSubscribeRequest(channels: [.workspaceBar, .workspaceBar])
            )
        )
        let subscribeResponse = try await connection.readResponse()
        #expect(subscribeResponse.ok)
        #expect(subscribeResponse.kind == .subscribe)
        #expect(subscribeResponse.status == .subscribed)
        if case let .subscribed(payload)? = subscribeResponse.result?.payload {
            #expect(payload.channels == [.workspaceBar])
        } else {
            Issue.record("Expected subscribed payload")
        }

        let events = await connection.eventStream()
        var iterator = events.makeAsyncIterator()
        let initialNextEvent = try await iterator.next()
        let initialEvent = try #require(initialNextEvent)
        #expect(initialEvent.channel == .workspaceBar)

        controller.requestWorkspaceBarRefresh()
        controller.requestWorkspaceBarRefresh()
        controller.requestWorkspaceBarRefresh()
        await controller.waitForWorkspaceBarRefreshForTests()

        let nextEvent = try await iterator.next()
        let event = try #require(nextEvent)
        #expect(event.channel == .workspaceBar)
        #expect(event.ok)
        #expect(event.status == .success)
        #expect(!event.id.isEmpty)
        #expect(controller.workspaceBarRefreshDebugState.requestCount == 3)
        #expect(controller.workspaceBarRefreshDebugState.executionCount == 1)

        if case let .workspaceBar(payload) = event.result.payload {
            let ids = payload.monitors
                .flatMap(\.workspaces)
                .flatMap(\.windows)
                .map(\.id)
            #expect(
                ids.contains {
                    IPCWindowOpaqueID.decode($0, expectingSessionToken: ipcServerTestSessionToken)?.pid == 9201
                }
            )
        } else {
            Issue.record("Expected workspace-bar event payload")
        }
    }

    @Test func workspaceBarSubscriptionStillPublishesWhenLocalBarsAreDisabled() async throws {
        let socketPath = makeIPCTestSocketPath()
        let controller = makeLayoutPlanTestController()
        controller.settings.workspaceBarEnabled = false
        controller.settings.monitorBarSettings = []
        controller.settings.statusBarShowWorkspaceName = false
        controller.resetWorkspaceBarRefreshDebugStateForTests()

        let workspaceId = controller.workspaceManager.workspaceId(for: "1", createIfMissing: false)!
        controller.appInfoCache.storeInfoForTests(pid: 9301, name: "Terminal", bundleId: "com.example.terminal")
        _ = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1501),
            pid: 9301,
            windowId: 1501,
            to: workspaceId
        )

        let server = IPCServer(
            controller: controller,
            socketPath: socketPath,
            sessionToken: ipcServerTestSessionToken
        )
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        try server.start()

        let client = IPCClient(socketPath: socketPath)
        let connection = try client.openConnection()
        defer {
            Task {
                await connection.close()
            }
        }

        try await connection.send(
            IPCRequest(
                id: "sub-workspace-bar-disabled",
                subscribe: IPCSubscribeRequest(channels: [.workspaceBar])
            )
        )
        let subscribeResponse = try await connection.readResponse()
        #expect(subscribeResponse.ok)
        #expect(subscribeResponse.kind == .subscribe)
        #expect(subscribeResponse.status == .subscribed)

        let events = await connection.eventStream()
        var iterator = events.makeAsyncIterator()
        let initialNextEvent = try await iterator.next()
        let initialEvent = try #require(initialNextEvent)
        #expect(initialEvent.channel == .workspaceBar)

        controller.requestWorkspaceBarRefresh()
        controller.requestWorkspaceBarRefresh()
        controller.requestWorkspaceBarRefresh()
        await controller.waitForWorkspaceBarRefreshForTests()

        let nextEvent = try await iterator.next()
        let event = try #require(nextEvent)
        #expect(event.channel == .workspaceBar)
        #expect(event.ok)
        #expect(event.status == .success)
        #expect(!event.id.isEmpty)
        #expect(controller.workspaceBarRefreshDebugState.requestCount == 3)
        #expect(controller.workspaceBarRefreshDebugState.scheduledCount == 1)
        #expect(controller.workspaceBarRefreshDebugState.executionCount == 1)

        if case let .workspaceBar(payload) = event.result.payload {
            #expect(payload.monitors.count == controller.workspaceManager.monitors.count)
        } else {
            Issue.record("Expected workspace-bar event payload")
        }
    }
}
