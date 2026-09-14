// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Darwin
import Foundation

@MainActor
final class SettingsFileObservation {
    private struct FileIdentity: Equatable {
        let deviceID: UInt64
        let inode: UInt64

        init(_ fingerprint: SettingsFileAccess.Fingerprint) {
            deviceID = fingerprint.deviceID
            inode = fingerprint.inode
        }
    }

    private let directoryURL: URL
    private let fileURL: URL
    private weak var persistence: SettingsFilePersistence?
    private var directoryFileDescriptor: CInt = -1
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var settingsFileDescriptor: CInt = -1
    private var settingsFileWatcher: DispatchSourceFileSystemObject?
    private var watchedSettingsFileIdentity: FileIdentity?

    init(directoryURL: URL, fileURL: URL) {
        self.directoryURL = directoryURL
        self.fileURL = fileURL
    }

    deinit {
        settingsFileWatcher?.cancel()
        if settingsFileWatcher == nil, settingsFileDescriptor >= 0 {
            close(settingsFileDescriptor)
        }
        directoryWatcher?.cancel()
        if directoryWatcher == nil, directoryFileDescriptor >= 0 {
            close(directoryFileDescriptor)
        }
    }

    func attach(to persistence: SettingsFilePersistence) {
        precondition(self.persistence == nil)
        self.persistence = persistence
    }

    func start() {
        do {
            try SettingsFileAccess.ensureDirectoryExists(at: directoryURL)
        } catch {
            Log.config.error("Failed to create settings directory \(directoryURL.path): \(error.localizedDescription)")
            return
        }

        startDirectoryWatcher()
        refresh()
    }

    private func startDirectoryWatcher() {
        directoryFileDescriptor = open(directoryURL.path, O_EVTONLY)
        guard directoryFileDescriptor >= 0 else {
            Log.config.error("Failed to watch settings directory \(directoryURL.path).")
            return
        }

        let fileDescriptor = directoryFileDescriptor
        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            queue: .main
        )
        watcher.setEventHandler { [weak persistence] in
            persistence?.handlePossibleSettingsFileChange()
        }
        watcher.setCancelHandler { [weak self] in
            close(fileDescriptor)
            self?.directoryFileDescriptor = -1
        }
        directoryWatcher = watcher
        watcher.resume()
    }

    func refresh(for observedFingerprint: SettingsFileAccess.Fingerprint? = nil) {
        let fingerprint = observedFingerprint ?? SettingsFileAccess.currentFingerprint(at: fileURL)
        guard let fingerprint else {
            cancelSettingsFileWatcher()
            return
        }

        let identity = FileIdentity(fingerprint)
        guard settingsFileWatcher == nil || watchedSettingsFileIdentity != identity else { return }

        cancelSettingsFileWatcher()

        let fileDescriptor = open(fileURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            settingsFileDescriptor = -1
            watchedSettingsFileIdentity = nil
            Log.config.error("Failed to watch settings file \(fileURL.path).")
            return
        }

        settingsFileDescriptor = fileDescriptor
        watchedSettingsFileIdentity = identity

        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        watcher.setEventHandler { [weak persistence] in
            persistence?.handlePossibleSettingsFileChange()
        }
        watcher.setCancelHandler { [weak self] in
            close(fileDescriptor)
            if self?.settingsFileDescriptor == fileDescriptor {
                self?.settingsFileDescriptor = -1
            }
        }
        settingsFileWatcher = watcher
        watcher.resume()
    }

    private func cancelSettingsFileWatcher() {
        settingsFileWatcher?.cancel()
        settingsFileWatcher = nil
        settingsFileDescriptor = -1
        watchedSettingsFileIdentity = nil
    }
}
