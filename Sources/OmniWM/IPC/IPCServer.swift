// SPDX-License-Identifier: GPL-2.0-only
import Darwin
import Foundation
import OmniWMIPC

protocol IPCServerLifecycle: AnyObject {
    @MainActor func start() throws
    @MainActor func stop()
}

actor IPCConnectionRegistry {
    private var connections: [UUID: IPCConnection] = [:]

    func insert(_ connection: IPCConnection) {
        connections[connection.id] = connection
    }

    func remove(id: UUID) {
        connections.removeValue(forKey: id)
    }

    func stopAll() async {
        let currentConnections = Array(connections.values)
        connections.removeAll()
        for connection in currentConnections {
            await connection.stop()
        }
    }
}

final class IPCServer: IPCServerLifecycle {
    let socketPath: String

    private let controller: WMController
    private let bridge: IPCApplicationBridge
    private let authorizationToken: String
    private let connectionRegistry = IPCConnectionRegistry()
    private let queue = DispatchQueue(label: "com.barut.OmniWM.ipc.server")
    private let fileManager: FileManager
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    @MainActor
    init(
        controller: WMController,
        socketPath: String = IPCSocketPath.resolvedPath(),
        fileManager: FileManager = .default,
        versionProvider: @escaping () -> String? = { Bundle.main.appVersion },
        sessionToken: String = UUID().uuidString,
        authorizationToken: String = UUID().uuidString
    ) {
        self.controller = controller
        self.socketPath = socketPath
        self.fileManager = fileManager
        self.authorizationToken = authorizationToken
        bridge = IPCApplicationBridge(
            controller: controller,
            appVersion: versionProvider(),
            sessionToken: sessionToken,
            authorizationToken: authorizationToken
        )
    }

    @MainActor
    func start() throws {
        try ensureSocketDirectoryExists()
        try ZigIPCSupport.removeExistingSocketIfNeeded(at: socketPath)

        var bindError: Error?
        queue.sync {
            do {
                let fd = try ZigIPCSupport.makeListeningSocket(at: socketPath)
                listenFD = fd

                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler(handler: makeAcceptSourceHandler())
                acceptSource = source
                source.resume()
            } catch {
                bindError = error
            }
        }

        if let bindError {
            stop()
            throw bindError
        }

        do {
            try writeAuthorizationToken()
        } catch {
            stop()
            throw error
        }
        controller.ipcApplicationBridge = bridge
    }

    @MainActor
    func stop() {
        if controller.ipcApplicationBridge === bridge {
            controller.ipcApplicationBridge = nil
        }
        let bridge = self.bridge
        let connectionRegistry = self.connectionRegistry
        Task {
            await bridge.shutdown()
            await connectionRegistry.stopAll()
        }

        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil

            if listenFD >= 0 {
                close(listenFD)
                listenFD = -1
            }

            _ = unlink(socketPath)
            _ = unlink(secretPath)
        }
    }

    private func makeAcceptSourceHandler() -> () -> Void {
        { [weak self] in
            self?.acceptConnections()
        }
    }

    private func acceptConnections() {
        guard listenFD >= 0 else { return }

        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    break
                }
                return
            }

            guard ZigIPCSupport.isCurrentUser(clientFD) else {
                close(clientFD)
                continue
            }

            guard (try? ZigIPCSupport.configureSocket(clientFD, nonBlocking: false)) != nil else {
                close(clientFD)
                continue
            }
            let connectionRegistry = self.connectionRegistry
            let bridge = self.bridge
            Task {
                let connection = IPCConnection(
                    handle: FileHandle(fileDescriptor: clientFD, closeOnDealloc: true),
                    bridge: bridge,
                    onClose: { id in
                        Task {
                            await connectionRegistry.remove(id: id)
                        }
                    }
                )

                await connectionRegistry.insert(connection)
                await connection.start()
            }
        }
    }

    @MainActor
    private func ensureSocketDirectoryExists() throws {
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    @MainActor
    private func writeAuthorizationToken() throws {
        _ = fileManager
        try ZigIPCSupport.writeSecretToken(authorizationToken, forSocketPath: socketPath)
    }

    private var secretPath: String {
        IPCSocketPath.secretPath(forSocketPath: socketPath)
    }
}
