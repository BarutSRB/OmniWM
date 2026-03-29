import Foundation
import OmniWMIPC

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

    private nonisolated static func runReadLoop(fileDescriptor: Int32, owner: IPCConnection) async {
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
        do {
            let request = try IPCWire.decodeRequest(from: Data(line.utf8))
            let response = await bridge.response(for: request)
            try send(response)

            guard response.ok,
                  case let .subscribe(subscribeRequest) = request.payload
            else {
                return
            }

            let channels = IPCAutomationManifest.expandedChannels(for: subscribeRequest)

            for channel in channels where eventTasks[channel] == nil {
                let stream = await bridge.stream(for: channel)
                let task = Task(priority: .utility) {
                    for await event in stream {
                        do {
                            try await self.send(event)
                        } catch {
                            await self.stop()
                            return
                        }
                    }
                }
                eventTasks[channel] = task
            }

            for event in await bridge.initialEvents(for: subscribeRequest) {
                try send(event)
            }
        } catch {
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

    private nonisolated static func readNextLine(from fileDescriptor: Int32, buffer: inout Data) throws -> String? {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                guard newlineIndex <= maxRequestLineBytes else {
                    throw ReadLoopError.requestTooLarge
                }
                let lineData = buffer.prefix(upTo: newlineIndex)
                buffer.removeSubrange(...newlineIndex)
                guard let line = String(data: lineData, encoding: .utf8) else {
                    throw POSIXError(.EINVAL)
                }
                return line
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

            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                guard newlineIndex <= maxRequestLineBytes else {
                    throw ReadLoopError.requestTooLarge
                }
                continue
            }

            if buffer.count > maxRequestLineBytes {
                throw ReadLoopError.requestTooLarge
            }
        }
    }

    private nonisolated static func readChunk(from fileDescriptor: Int32) throws -> Data? {
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
