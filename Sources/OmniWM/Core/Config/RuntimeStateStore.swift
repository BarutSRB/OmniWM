// SPDX-License-Identifier: GPL-2.0-only
import Darwin
import Foundation

struct RuntimeState: Codable, Equatable {
    var windowRestoreCatalog: PersistedWindowRestoreCatalog?
    var updaterLastCheckedAt: Date?
    var updaterSkippedReleaseTag: String?
    var commandPaletteLastMode: String?
    var hiddenBarIsCollapsed: Bool?
}

@MainActor
final class RuntimeStateStore {
    nonisolated static let defaultDirectoryURL = OmniWMStoragePaths.live.stateDirectory
    nonisolated static let fileName = "runtime-state.json"
    nonisolated static let defaultCommandPaletteLastMode = CommandPaletteMode.windows
    nonisolated static let defaultHiddenBarIsCollapsed = true
    nonisolated static var fileURL: URL {
        defaultDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
    }

    let directoryURL: URL
    let fileURL: URL

    private let deferSaves: Bool
    private var state: RuntimeState
    private var pendingState: RuntimeState?
    private var saveScheduled = false

    init(
        directory: URL = RuntimeStateStore.defaultDirectoryURL,
        deferSaves: Bool = true
    ) {
        directoryURL = directory
        fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        self.deferSaves = deferSaves
        state = Self.readState(from: directory.appendingPathComponent(Self.fileName, isDirectory: false))
    }

    func load() -> RuntimeState {
        state
    }

    func save(_ state: RuntimeState) {
        self.state = state
        write(state)
    }

    @discardableResult
    func importWindowRestoreCatalogIfMissing(fromLegacyDirectory legacyDirectory: URL?) -> Bool {
        guard state.windowRestoreCatalog?.entries.isEmpty ?? true,
              let legacyDirectory
        else {
            return false
        }

        let legacyFileURL = legacyDirectory.appendingPathComponent(Self.fileName, isDirectory: false)
        guard legacyFileURL.standardizedFileURL != fileURL.standardizedFileURL else {
            return false
        }

        let legacyState = Self.readState(from: legacyFileURL)
        guard let legacyCatalog = legacyState.windowRestoreCatalog,
              !legacyCatalog.entries.isEmpty
        else {
            return false
        }

        let previousState = state
        state.windowRestoreCatalog = legacyCatalog
        pendingState = nil

        do {
            try writeState(state)
            try? FileManager.default.removeItem(at: legacyFileURL)
            return true
        } catch {
            state = previousState
            report("Failed to import \(legacyFileURL.path): \(error.localizedDescription)")
            return false
        }
    }

    func scheduleSave() {
        if !deferSaves {
            pendingState = nil
            write(state)
            return
        }

        pendingState = state
        guard !saveScheduled else { return }
        saveScheduled = true

        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            saveScheduled = false
            flushNow()
        }
    }

    func flushNow() {
        guard let state = pendingState else { return }
        pendingState = nil
        write(state)
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
            state.commandPaletteLastMode.flatMap(CommandPaletteMode.init(rawValue:)) ?? Self.defaultCommandPaletteLastMode
        }
        set {
            guard commandPaletteLastMode != newValue else { return }
            state.commandPaletteLastMode = newValue.rawValue
            scheduleSave()
        }
    }

    var hiddenBarIsCollapsed: Bool {
        get { state.hiddenBarIsCollapsed ?? Self.defaultHiddenBarIsCollapsed }
        set {
            guard hiddenBarIsCollapsed != newValue else { return }
            state.hiddenBarIsCollapsed = newValue
            scheduleSave()
        }
    }

    private func write(_ state: RuntimeState) {
        do {
            try writeState(state)
        } catch {
            report("Failed to save \(fileURL.path): \(error.localizedDescription)")
        }
    }

    private func writeState(_ state: RuntimeState) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try Self.applyPermissions(S_IRWXU, to: directoryURL)
        let data = try JSONEncoder().encode(state)
        try Self.writePrivateData(data, to: fileURL)
    }

    private static func writePrivateData(_ data: Data, to fileURL: URL) throws {
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

    private static func applyPermissions(_ permissions: mode_t, to url: URL) throws {
        let result = url.withUnsafeFileSystemRepresentation { path -> CInt in
            guard let path else { return -1 }
            return Darwin.chmod(path, permissions)
        }

        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func replaceItem(at destinationURL: URL, with sourceURL: URL) throws {
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
            fputs("[RuntimeStateStore] Failed to load \(url.path): \(error.localizedDescription)\n", stderr)
            return RuntimeState()
        }
    }

    private func report(_ message: String) {
        fputs("[RuntimeStateStore] \(message)\n", stderr)
    }
}
