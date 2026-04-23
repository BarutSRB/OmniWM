// SPDX-License-Identifier: GPL-2.0-only
import Foundation

struct RuntimeState: Codable, Equatable {
    var windowRestoreCatalog: PersistedWindowRestoreCatalog?
    var updaterLastCheckedAt: Date?
    var updaterSkippedReleaseTag: String?
}

@MainActor
final class RuntimeStateStore {
    nonisolated static let defaultDirectoryURL = SettingsFilePersistence.defaultDirectoryURL
    nonisolated static let fileName = "runtime-state.json"
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

    private func write(_ state: RuntimeState) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            report("Failed to save \(fileURL.path): \(error.localizedDescription)")
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
