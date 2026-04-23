// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import OmniWMIPC

struct IPCConnectionSubscriptionTestHooks {
    var afterSubscribeResponseBeforeEventDelivery: (@Sendable () async -> Void)?
}

private final class IPCConnectionSubscriptionTestHookStore: @unchecked Sendable {
    private let lock = NSLock()
    private var hooks: IPCConnectionSubscriptionTestHooks?

    func set(_ hooks: IPCConnectionSubscriptionTestHooks?) {
        lock.lock()
        self.hooks = hooks
        lock.unlock()
    }

    func get() -> IPCConnectionSubscriptionTestHooks? {
        lock.lock()
        let hooks = self.hooks
        lock.unlock()
        return hooks
    }
}

private let ipcConnectionSubscriptionTestHookStore = IPCConnectionSubscriptionTestHookStore()

actor IPCConnection {
    private enum ReadLoopError: Error {
        case requestTooLarge
    }

    static let maxRequestLineBytes = 64 * 1024

    nonisolated let id = UUID()

    private let handle: FileHandle
    private let bridge: IPCApplicationBridge
    private let onClose: @Sendable (UUID) -> Void
    private var readTask: Task<Void, Never>?
    private var eventTasks: [IPCSubscriptionChannel: Task<Void, Never>] = [:]
    private var isClosed = false

    init(
        handle: FileHandle,
        bridge: IPCApplicationBridge,
        onClose: @escaping @Sendable (UUID) -> Void
    ) {
        self.handle = handle
        self.bridge = bridge
        self.onClose = onClose
    }

    func start() {
        guard readTask == nil else { return }
        let fileDescriptor = handle.fileDescriptor
        readTask = Task(priority: .userInitiated) {
            await Self.runReadLoop(fileDescriptor: fileDescriptor, owner: self)
        }
    }

    func stop() {
        closeIfNeeded()
    }

    nonisolated static func setSubscriptionTestHooksForTests(_ hooks: IPCConnectionSubscriptionTestHooks?) {
        ipcConnectionSubscriptionTestHookStore.set(hooks)
    }

    nonisolated private static func runReadLoop(fileDescriptor: Int32, owner: IPCConnection) async {
        var readBuffer = Data()
        do {
            while let line = try readNextLine(from: fileDescriptor, buffer: &readBuffer) {
                if Task.isCancelled {
                    break
                }
                await owner.process(line)
            }
        } catch {
            await owner.handleReadLoopError(error)
        }

        await owner.finishReadLoop()
    }

    private func process(_ line: String) async {
        var pendingRegistrations: [IPCEventStreamRegistration] = []
        do {
            let request = try IPCWire.decodeRequest(from: Data(line.utf8))
            let response = await bridge.response(for: request)

            guard response.ok,
                  case let .subscribe(subscribeRequest) = request.payload
            else {
                try send(response)
                return
            }

            let channels = IPCAutomationManifest.expandedChannels(for: subscribeRequest)
            let newChannels = channels.filter { eventTasks[$0] == nil }

            pendingRegistrations.reserveCapacity(newChannels.count)
            for channel in newChannels {
                let registration = await bridge.registerStream(for: channel)
                pendingRegistrations.append(registration)
            }

            let initialEvents = subscribeRequest.sendInitial
                ? await bridge.initialEvents(for: newChannels)
                : []

            try send(response)

            if let hook = Self.subscriptionTestHooksForTests()?.afterSubscribeResponseBeforeEventDelivery {
                await hook()
            }

            for event in initialEvents {
                try send(event)
            }

            for registration in pendingRegistrations {
                let task = Task(priority: .utility) {
                    for await event in registration.stream {
                        do {
                            try self.send(event)
                        } catch {
                            self.stop()
                            return
                        }
                    }
                }
                eventTasks[registration.channel] = task
            }
        } catch {
            for registration in pendingRegistrations {
                await bridge.unregisterStream(registration)
            }
            do {
                try send(IPCResponse.failure(id: "", kind: .error, code: .invalidRequest))
            } catch {
                closeIfNeeded()
            }
        }
    }

    private func handleReadLoopError(_ error: Error) {
        guard let readLoopError = error as? ReadLoopError else {
            return
        }

        switch readLoopError {
        case .requestTooLarge:
            try? send(IPCResponse.failure(id: "", kind: .error, code: .invalidRequest))
        }
    }

    private func send(_ response: IPCResponse) throws {
        guard !isClosed else { throw POSIXError(.ECANCELED) }
        try handle.write(contentsOf: IPCWire.encodeResponseLine(response))
    }

    private func send(_ event: IPCEventEnvelope) throws {
        guard !isClosed else { throw POSIXError(.ECANCELED) }
        try handle.write(contentsOf: IPCWire.encodeEventLine(event))
    }

    private func finishReadLoop() {
        closeIfNeeded()
    }

    nonisolated private static func subscriptionTestHooksForTests() -> IPCConnectionSubscriptionTestHooks? {
        ipcConnectionSubscriptionTestHookStore.get()
    }

    nonisolated private static func readNextLine(from fileDescriptor: Int32, buffer: inout Data) throws -> String? {
        while true {
            switch ZigIPCSupport.scanLine(in: buffer, maxLineBytes: maxRequestLineBytes) {
            case let .line(newlineIndex):
                let lineData = buffer.prefix(upTo: newlineIndex)
                buffer.removeSubrange(...newlineIndex)
                guard let line = String(data: lineData, encoding: .utf8) else {
                    throw POSIXError(.EINVAL)
                }
                return line
            case .overflow:
                throw ReadLoopError.requestTooLarge
            case .invalidArgument:
                throw POSIXError(.EINVAL)
            case .noNewline:
                break
            }

            guard let chunk = try readChunk(from: fileDescriptor), !chunk.isEmpty else {
                guard !buffer.isEmpty else { return nil }
                let remaining = buffer
                buffer.removeAll()
                guard let line = String(data: remaining, encoding: .utf8) else {
                    throw POSIXError(.EINVAL)
                }
                return line
            }

            buffer.append(chunk)
        }
    }

    nonisolated private static func readChunk(from fileDescriptor: Int32) throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                return Data(buffer[0..<count])
            }
            if count == 0 {
                return nil
            }
            if errno == EINTR {
                continue
            }
            let error = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(error)
        }
    }

    private func closeIfNeeded() {
        guard !isClosed else { return }
        isClosed = true

        let tasks = Array(eventTasks.values)
        eventTasks.removeAll()

        let currentReadTask = readTask
        readTask = nil
        currentReadTask?.cancel()

        for task in tasks {
            task.cancel()
        }

        try? handle.close()
        onClose(id)
    }
}
