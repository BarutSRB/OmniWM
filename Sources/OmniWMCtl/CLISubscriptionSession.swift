// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Darwin
import Foundation
import OmniWMIPC

final class CLIConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: IPCClientConnection?

    func open(with environment: CLIRuntimeEnvironment) throws -> IPCClientConnection {
        let connection = try environment.openConnection()
        lock.lock()
        current = connection
        lock.unlock()
        return connection
    }

    func interruptCurrent() {
        lock.lock()
        let connection = current
        lock.unlock()
        connection?.interrupt()
    }

    func closeCurrent() {
        lock.lock()
        let connection = current
        current = nil
        lock.unlock()
        guard let connection else { return }
        connection.interrupt()
        Task {
            await connection.close()
        }
    }
}

struct CLISubscriptionSession {
    let connection: IPCClientConnection
    let response: IPCResponse

    private static let reconnectInitialDelay: Duration = .milliseconds(500)
    private static let reconnectMaximumDelay: Duration = .seconds(5)

    static func open(
        requestID: String,
        subscription: IPCSubscribeRequest,
        sendInitial: Bool,
        connections: CLIConnectionBox,
        environment: CLIRuntimeEnvironment
    ) async throws -> Self {
        let connection = try connections.open(with: environment)
        try await connection.send(IPCRequest(
            id: requestID,
            subscribe: IPCSubscribeRequest(
                channels: subscription.channels,
                allChannels: subscription.allChannels,
                sendInitial: sendInitial
            )
        ))
        return Self(connection: connection, response: try await connection.readResponse())
    }

    static func reconnect(
        requestID: String,
        subscription: IPCSubscribeRequest,
        connections: CLIConnectionBox,
        environment: CLIRuntimeEnvironment
    ) async throws -> Self {
        var delay = reconnectInitialDelay
        while true {
            try await environment.sleep(delay)
            try Task.checkCancellation()
            delay = min(delay * 2, reconnectMaximumDelay)
            do {
                return try await open(
                    requestID: requestID,
                    subscription: subscription,
                    sendInitial: true,
                    connections: connections,
                    environment: environment
                )
            } catch let error where CLIRuntimeOutput.isTransportError(error) {
                connections.closeCurrent()
                CLIRuntimeOutput.writeNotice("omniwmctl: reconnect failed: \(error)")
            }
        }
    }
}
