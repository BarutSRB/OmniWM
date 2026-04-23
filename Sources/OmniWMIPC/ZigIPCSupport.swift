// SPDX-License-Identifier: GPL-2.0-only
import COmniWMKernels
import Darwin
import Foundation

public enum ZigIPCSupport {
    public enum LineScanResult: Equatable {
        case noNewline
        case overflow
        case invalidArgument
        case line(Int)
    }

    private static let defaultSocketSuffix = "/Library/Caches/com.barut.OmniWM/ipc.sock"
    public static let bundleIDValidationNone: UInt32 = 0
    public static let bundleIDValidationRequired: UInt32 = 1
    public static let bundleIDValidationInvalid: UInt32 = 2

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: Darwin.errno) ?? .EIO)
    }

    private static func withOptionalCString<Result>(
        _ value: String?,
        _ body: (UnsafePointer<CChar>?) -> Result
    ) -> Result {
        guard let value else {
            return body(nil)
        }
        return value.withCString(body)
    }

    private static func renderString(
        initialCapacity: Int = 128,
        _ body: (UnsafeMutablePointer<CChar>, Int) -> Int64
    ) -> String? {
        var capacity = max(initialCapacity, 64)

        while true {
            var buffer = [CChar](repeating: 0, count: capacity)
            let writtenLength = buffer.withUnsafeMutableBufferPointer { bufferPointer -> Int64 in
                guard let baseAddress = bufferPointer.baseAddress else {
                    return -1
                }
                return body(baseAddress, bufferPointer.count)
            }
            if writtenLength >= 0 {
                let length = Int(writtenLength)
                guard length <= buffer.count else {
                    Darwin.errno = EOVERFLOW
                    return nil
                }

                let utf8 = buffer.prefix(length).map { UInt8(bitPattern: $0) }
                return String(decoding: utf8, as: UTF8.self)
            }

            if Darwin.errno == ERANGE {
                capacity *= 2
                continue
            }

            return nil
        }
    }

    public static func resolvedSocketPath(
        overridePath: String?,
        homePath: String = NSHomeDirectory()
    ) -> String {
        withOptionalCString(overridePath) { overridePointer in
            homePath.withCString { homePointer in
                renderString(initialCapacity: 256) { output, outputCapacity in
                    omniwm_ipc_resolved_socket_path(
                        overridePointer,
                        homePointer,
                        output,
                        outputCapacity
                    )
                }
            }
        } ?? (homePath + defaultSocketSuffix)
    }

    public static func secretPath(forSocketPath socketPath: String) -> String {
        socketPath.withCString { socketPathPointer in
            renderString(initialCapacity: socketPath.utf8.count + 32) { output, outputCapacity in
                omniwm_ipc_secret_path(
                    socketPathPointer,
                    output,
                    outputCapacity
                )
            }
        } ?? (socketPath + IPCSocketPath.secretSuffix)
    }

    public static func bundleIDValidationCode(for bundleID: String?) -> UInt32 {
        withOptionalCString(bundleID) { bundleIDPointer in
            omniwm_ipc_bundle_id_validation_code(bundleIDPointer)
        }
    }

    public static func automationManifestJSON() -> String? {
        renderString(initialCapacity: 32 * 1024) { output, outputCapacity in
            omniwm_ipc_automation_manifest_json(output, outputCapacity)
        }
    }

    public static func normalizedWorkspaceID(_ candidate: String) -> String? {
        candidate.withCString { candidatePointer in
            renderString(initialCapacity: max(candidate.utf8.count + 1, 32)) { output, outputCapacity in
                omniwm_workspace_id_normalize(candidatePointer, output, outputCapacity)
            }
        }
    }

    public static func workspaceID(fromNumber workspaceNumber: Int) -> String? {
        guard workspaceNumber > 0 else { return nil }
        return renderString(initialCapacity: 32) { output, outputCapacity in
            omniwm_workspace_id_from_number(UInt64(workspaceNumber), output, outputCapacity)
        }
    }

    public static func workspaceNumber(fromRawID rawID: String) -> Int? {
        rawID.withCString { rawIDPointer in
            var workspaceNumber: UInt64 = 0
            let didParse = omniwm_workspace_number_from_raw_id(rawIDPointer, &workspaceNumber) != 0
            guard didParse else { return nil }
            return Int(exactly: workspaceNumber)
        }
    }

    public static func scanLine(in data: Data, maxLineBytes: Int) -> LineScanResult {
        let scanResult = data.withUnsafeBytes { rawBuffer -> Int64 in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return omniwm_ipc_find_newline(bytes.baseAddress, bytes.count, max(0, maxLineBytes))
        }

        switch scanResult {
        case Int64(OMNIWM_IPC_LINE_SCAN_NO_NEWLINE):
            return .noNewline
        case Int64(OMNIWM_IPC_LINE_SCAN_OVERFLOW):
            return .overflow
        case Int64(OMNIWM_IPC_LINE_SCAN_INVALID_ARGUMENT):
            return .invalidArgument
        default:
            return .line(Int(scanResult))
        }
    }

    public static func connectSocket(at path: String) throws -> Int32 {
        let fileDescriptor = path.withCString { pathPointer in
            omniwm_ipc_socket_connect(pathPointer)
        }
        guard fileDescriptor >= 0 else {
            throw posixError()
        }
        return fileDescriptor
    }

    public static func removeExistingSocketIfNeeded(at path: String) throws {
        let result = path.withCString { pathPointer in
            omniwm_ipc_socket_remove_existing_if_needed(pathPointer)
        }
        guard result == 0 else {
            throw posixError()
        }
    }

    public static func isSocketActive(at path: String) throws -> Bool {
        let result = path.withCString { pathPointer in
            omniwm_ipc_socket_is_active(pathPointer)
        }
        if result < 0 {
            throw posixError()
        }
        return result != 0
    }

    public static func makeListeningSocket(at path: String) throws -> Int32 {
        let fileDescriptor = path.withCString { pathPointer in
            omniwm_ipc_socket_make_listening(pathPointer)
        }
        guard fileDescriptor >= 0 else {
            throw posixError()
        }
        return fileDescriptor
    }

    public static func configureSocket(_ fileDescriptor: Int32, nonBlocking: Bool) throws {
        let result = omniwm_ipc_socket_configure(fileDescriptor, nonBlocking ? 1 : 0)
        guard result == 0 else {
            throw posixError()
        }
    }

    public static func isCurrentUser(_ fileDescriptor: Int32) -> Bool {
        omniwm_ipc_socket_is_current_user(fileDescriptor) == 1
    }

    public static func writeSecretToken(
        _ token: String,
        forSocketPath socketPath: String
    ) throws {
        let result = socketPath.withCString { socketPathPointer in
            token.withCString { tokenPointer in
                omniwm_ipc_write_secret_token(socketPathPointer, tokenPointer)
            }
        }
        guard result == 0 else {
            throw posixError()
        }
    }

    public static func readSecretToken(forSocketPath socketPath: String) -> String? {
        socketPath.withCString { socketPathPointer in
            renderString(initialCapacity: 128) { output, outputCapacity in
                omniwm_ipc_read_secret_token_for_socket(socketPathPointer, output, outputCapacity)
            }
        }
    }
}
