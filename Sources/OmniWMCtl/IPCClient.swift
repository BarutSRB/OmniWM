// SPDX-License-Identifier: GPL-2.0-only
import Darwin
import Foundation
import OmniWMIPC

struct IPCClient {
    let socketPath: String
    let authorizationToken: String?
    let fileManager: FileManager

    init(
        socketPath: String = IPCSocketPath.resolvedPath(),
        authorizationToken: String? = nil,
        fileManager: FileManager = .default
    ) {
        self.socketPath = socketPath
        self.authorizationToken = authorizationToken
        self.fileManager = fileManager
    }

    func openConnection() throws -> IPCClientConnection {
        return IPCClientConnection(
            handle: FileHandle(fileDescriptor: try ZigIPCSupport.connectSocket(at: socketPath), closeOnDealloc: true),
            authorizationToken: resolvedAuthorizationToken()
        )
    }

    private func resolvedAuthorizationToken() -> String? {
        if let authorizationToken {
            return authorizationToken
        }

        _ = fileManager
        return ZigIPCSupport.readSecretToken(forSocketPath: socketPath)
    }
}

actor IPCClientConnection {
    private let handle: FileHandle
    private let fileDescriptor: Int32
    private let authorizationToken: String?
    private var readBuffer = Data()

    init(handle: FileHandle, authorizationToken: String?) {
        self.handle = handle
        self.fileDescriptor = handle.fileDescriptor
        self.authorizationToken = authorizationToken
    }

    func send(_ request: IPCRequest) throws {
        try handle.write(contentsOf: IPCWire.encodeRequestLine(request.authorizing(with: authorizationToken)))
    }

    func readResponse() throws -> IPCResponse {
        guard let line = try readNextLine() else {
            throw POSIXError(.ECONNRESET)
        }
        return try IPCWire.decodeResponse(from: Data(line.utf8))
    }

    func readEvent() throws -> IPCEventEnvelope? {
        guard let line = try readNextLine() else {
            return nil
        }
        return try IPCWire.decodeEvent(from: Data(line.utf8))
    }

    func hasPendingData(timeoutMilliseconds: Int32) throws -> Bool {
        if readBuffer.contains(0x0A) {
            return true
        }

        var descriptor = pollfd(
            fd: fileDescriptor,
            events: Int16(POLLIN),
            revents: 0
        )

        while true {
            let result = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
            if result > 0 {
                let readableMask = Int16(POLLIN | POLLHUP | POLLERR)
                return descriptor.revents & readableMask != 0
            }
            if result == 0 {
                return false
            }
            if errno == EINTR {
                continue
            }

            let error = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(error)
        }
    }

    func eventStream() -> AsyncThrowingStream<IPCEventEnvelope, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    while let event = try self.readEvent() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                self.interrupt()
                task.cancel()
            }
        }
    }

    func close() {
        interrupt()
        try? handle.close()
    }

    nonisolated func interrupt() {
        _ = Darwin.shutdown(fileDescriptor, SHUT_RDWR)
    }

    private func readNextLine() throws -> String? {
        while true {
            switch ZigIPCSupport.scanLine(in: readBuffer, maxLineBytes: .max) {
            case let .line(newlineIndex):
                let lineData = readBuffer.prefix(upTo: newlineIndex)
                readBuffer.removeSubrange(...newlineIndex)
                guard let line = String(data: lineData, encoding: .utf8) else {
                    throw POSIXError(.EINVAL)
                }
                return line
            case .overflow, .invalidArgument:
                throw POSIXError(.EINVAL)
            case .noNewline:
                break
            }

            guard let chunk = try readChunk(), !chunk.isEmpty else {
                guard !readBuffer.isEmpty else { return nil }
                let remaining = readBuffer
                readBuffer.removeAll()
                guard let line = String(data: remaining, encoding: .utf8) else {
                    throw POSIXError(.EINVAL)
                }
                return line
            }

            readBuffer.append(chunk)
        }
    }

    private func readChunk() throws -> Data? {
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
}
