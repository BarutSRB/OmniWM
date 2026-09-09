// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Darwin
import Foundation

struct RuntimeQuakeTerminalFrame: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(frame: CGRect) {
        x = frame.origin.x
        y = frame.origin.y
        width = frame.size.width
        height = frame.size.height
    }

    var frame: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct IssueDraft: Codable, Equatable, Sendable {
    var title: String = ""
    var actual: String = ""
    var expected: String = ""
    var repro: String = ""
    var affectedApps: String = ""
    var category: String = ""
    var layout: String = ""
    var regression: String = ""
    var regressionVersion: String = ""
    var polishedBody: String = ""
}

enum MonitorSetupStatus: String, Codable, Equatable, Sendable {
    case notPresented
    case dismissed
    case completed
}

struct RuntimeState: Codable, Equatable, Sendable {
    var windowRestoreCatalog: PersistedWindowRestoreCatalog?
    var updaterLastCheckedAt: Date?
    var updaterSkippedReleaseTag: String?
    var commandPaletteLastMode: String?
    var quakeTerminalUseCustomFrame: Bool?
    var quakeTerminalCustomFrame: RuntimeQuakeTerminalFrame?
    var issueDraft: IssueDraft?
    var hasSeenIssueWalkthrough: Bool?
    var monitorSetupStatus: MonitorSetupStatus?
}

@MainActor
final class RuntimeStateStore {
    nonisolated static let defaultDirectoryURL = OmniWMStoragePaths.live.stateDirectory
    nonisolated static let fileName = "runtime-state.json"
    nonisolated static let defaultCommandPaletteLastMode = CommandPaletteMode.windows
    nonisolated static let defaultQuakeTerminalUseCustomFrame = false
    nonisolated static let defaultMonitorSetupStatus = MonitorSetupStatus.notPresented
    let directoryURL: URL
    let fileURL: URL

    private struct PendingSave: Sendable {
        let revision: UInt64
        let state: RuntimeState
    }

    private let deferSaves: Bool
    private let saveQueue = DispatchQueue(label: "OmniWM.RuntimeStateStore", qos: .utility)
    private let writeState: @Sendable (RuntimeState, URL) throws -> Void
    private var state: RuntimeState
    private var pendingSave: PendingSave?
    private var saveRevision: UInt64 = 0
    private var saveTask: Task<Void, Never>?

    init(
        directory: URL = RuntimeStateStore.defaultDirectoryURL,
        deferSaves: Bool = true,
        writeState: @escaping @Sendable (RuntimeState, URL) throws -> Void = RuntimeStateStore.writeState
    ) {
        directoryURL = directory
        fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        self.deferSaves = deferSaves
        self.writeState = writeState
        state = Self.readState(from: directory.appendingPathComponent(Self.fileName, isDirectory: false))
    }

    func scheduleSave() {
        saveRevision &+= 1
        pendingSave = PendingSave(revision: saveRevision, state: state)
        if !deferSaves {
            flushNow()
            return
        }
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            guard let self else { return }
            defer { saveTask = nil }
            while let pendingSave {
                let write = writeState
                let url = fileURL
                let result: Result<Void, Error> = await withCheckedContinuation { continuation in
                    saveQueue.async {
                        continuation.resume(returning: Result { try write(pendingSave.state, url) })
                    }
                }
                if !completeSave(pendingSave, result: result), self.pendingSave?.revision == pendingSave.revision {
                    return
                }
            }
        }
    }

    func flushNow() {
        guard let pendingSave else { return }
        let write = writeState
        let url = fileURL
        let result = saveQueue.sync { Result { try write(pendingSave.state, url) } }
        _ = completeSave(pendingSave, result: result)
    }

    func waitForPendingSave() async {
        await saveTask?.value
    }

    private func completeSave(_ save: PendingSave, result: Result<Void, Error>) -> Bool {
        switch result {
        case .success:
            if pendingSave?.revision == save.revision {
                pendingSave = nil
            }
            return true
        case let .failure(error):
            Log.config.error("Failed to save \(fileURL.path): \(error.localizedDescription)")
            return false
        }
    }

    var windowRestoreCatalog: PersistedWindowRestoreCatalog? {
        get { state.windowRestoreCatalog }
        set {
            guard state.windowRestoreCatalog != newValue else { return }
            state.windowRestoreCatalog = newValue
            scheduleSave()
        }
    }

    var updaterLastCheckedAt: Date? {
        get { state.updaterLastCheckedAt }
        set {
            guard state.updaterLastCheckedAt != newValue else { return }
            state.updaterLastCheckedAt = newValue
            scheduleSave()
        }
    }

    var updaterSkippedReleaseTag: String? {
        get { state.updaterSkippedReleaseTag }
        set {
            guard state.updaterSkippedReleaseTag != newValue else { return }
            state.updaterSkippedReleaseTag = newValue
            scheduleSave()
        }
    }

    var commandPaletteLastMode: CommandPaletteMode {
        get {
            state.commandPaletteLastMode.flatMap(CommandPaletteMode.init(rawValue:)) ?? Self
                .defaultCommandPaletteLastMode
        }
        set {
            guard commandPaletteLastMode != newValue else { return }
            state.commandPaletteLastMode = newValue.rawValue
            scheduleSave()
        }
    }

    var quakeTerminalUseCustomFrame: Bool {
        get { state.quakeTerminalUseCustomFrame ?? Self.defaultQuakeTerminalUseCustomFrame }
        set {
            guard quakeTerminalUseCustomFrame != newValue else { return }
            state.quakeTerminalUseCustomFrame = newValue
            if !newValue {
                state.quakeTerminalCustomFrame = nil
            }
            scheduleSave()
        }
    }

    var quakeTerminalCustomFrame: CGRect? {
        get { state.quakeTerminalCustomFrame?.frame }
        set {
            let frame = newValue.map(RuntimeQuakeTerminalFrame.init(frame:))
            guard state.quakeTerminalCustomFrame != frame else { return }
            state.quakeTerminalCustomFrame = frame
            if frame == nil {
                state.quakeTerminalUseCustomFrame = false
            }
            scheduleSave()
        }
    }

    var issueDraft: IssueDraft? {
        get { state.issueDraft }
        set {
            guard state.issueDraft != newValue else { return }
            state.issueDraft = newValue
            scheduleSave()
        }
    }

    var hasSeenIssueWalkthrough: Bool {
        get { state.hasSeenIssueWalkthrough ?? false }
        set {
            guard hasSeenIssueWalkthrough != newValue else { return }
            state.hasSeenIssueWalkthrough = newValue
            scheduleSave()
        }
    }

    var monitorSetupStatus: MonitorSetupStatus {
        get { state.monitorSetupStatus ?? Self.defaultMonitorSetupStatus }
        set {
            guard monitorSetupStatus != newValue else { return }
            state.monitorSetupStatus = newValue
            scheduleSave()
        }
    }

    nonisolated static func writeState(_ state: RuntimeState, to fileURL: URL) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try applyPermissions(S_IRWXU, to: directoryURL)
        let data = try JSONEncoder().encode(state)
        try writePrivateData(data, to: fileURL)
    }

    private nonisolated static func writePrivateData(_ data: Data, to fileURL: URL) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        let tempURL = directoryURL.appendingPathComponent(".\(fileName).\(UUID().uuidString).tmp", isDirectory: false)

        do {
            try data.write(to: tempURL, options: .withoutOverwriting)
            try applyPermissions(S_IRUSR | S_IWUSR, to: tempURL)
            try replaceItem(at: fileURL, with: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    private nonisolated static func applyPermissions(_ permissions: mode_t, to url: URL) throws {
        let result = url.withUnsafeFileSystemRepresentation { path -> CInt in
            guard let path else { return -1 }
            return Darwin.chmod(path, permissions)
        }

        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private nonisolated static func replaceItem(at destinationURL: URL, with sourceURL: URL) throws {
        let result = sourceURL.withUnsafeFileSystemRepresentation { sourcePath -> CInt in
            guard let sourcePath else { return -1 }
            return destinationURL.withUnsafeFileSystemRepresentation { destinationPath -> CInt in
                guard let destinationPath else { return -1 }
                return Darwin.rename(sourcePath, destinationPath)
            }
        }

        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func readState(from url: URL) -> RuntimeState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return RuntimeState()
        }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(RuntimeState.self, from: data)
        } catch {
            Log.config.error("Failed to load \(url.path): \(error.localizedDescription)")
            return RuntimeState()
        }
    }
}
