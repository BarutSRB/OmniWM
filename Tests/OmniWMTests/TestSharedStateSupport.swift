// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation

@testable import OmniWM

private let testConfigurationDirectoryKey = "__omniwm.test.configurationDirectory"

private actor AXTestHooksLock {
    static let shared = AXTestHooksLock()

    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func unlock() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            isLocked = false
        }
    }
}

final class AXTestHooksLease: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false

    func release() {
        lock.lock()
        let shouldRelease = !released
        released = true
        lock.unlock()

        guard shouldRelease else { return }

        Task { @MainActor in
            resetAXTestSharedStateForTests()
            await AXTestHooksLock.shared.unlock()
        }
    }
}

@MainActor
func resetAXTestSharedStateForTests() {
    let contexts = Array(AppAXContext.contexts.values)
    AppAXContext.contexts.removeAll()
    for context in contexts {
        context.destroy()
    }

    AppAXContext.onWindowDestroyed = nil
    AppAXContext.onWindowMinimizedChanged = nil
    AppAXContext.onFocusedWindowChanged = nil
    AppAXContext.contextFactoryForTests = nil

    AXWindowService.axWindowRefProviderForTests = nil
    AXWindowService.setFrameResultProviderForTests = nil
    AXWindowService.fastFrameProviderForTests = nil
    AXWindowService.titleLookupProviderForTests = nil
    AXWindowService.timeSourceForTests = nil
    AXWindowService.clearTitleCacheForTests()
}

func acquireAXTestHooksLeaseForTests() async -> AXTestHooksLease {
    await AXTestHooksLock.shared.lock()
    await MainActor.run {
        resetAXTestSharedStateForTests()
    }
    return AXTestHooksLease()
}

func configurationDirectoryForTests(defaults: UserDefaults) -> URL {
    if let path = defaults.string(forKey: testConfigurationDirectoryKey) {
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("omniwm-config-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defaults.set(directory.path, forKey: testConfigurationDirectoryKey)
    return directory
}

@MainActor
func runtimeStateStoreForTests(defaults: UserDefaults) -> RuntimeStateStore {
    RuntimeStateStore(
        directory: configurationDirectoryForTests(defaults: defaults),
        deferSaves: false
    )
}

@MainActor
extension SettingsStore {
    convenience init(defaults: UserDefaults) {
        let directory = configurationDirectoryForTests(defaults: defaults)
        self.init(
            persistence: SettingsFilePersistence(
                directory: directory,
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: directory,
                deferSaves: false
            )
        )
    }
}

@MainActor
func resetSharedControllerStateForTests() {
    SettingsWindowController.shared.windowForTests?.close()
    AppRulesWindowController.shared.windowForTests?.close()
    SponsorsWindowController.shared.windowForTests?.close()
    UpdateWindowController.shared.windowForTests?.close()
    OwnedWindowRegistry.shared.resetForTests()
    ScreenLookupCache.shared.resetForTests()
    FrontmostApplicationState.shared.setSnapshotForTests(nil)

    resetAXTestSharedStateForTests()
}
