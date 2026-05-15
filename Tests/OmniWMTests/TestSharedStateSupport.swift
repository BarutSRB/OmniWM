import AppKit
import Foundation
@testable import OmniWM

private actor AXFrameProviderIsolationForTests {
    static let shared = AXFrameProviderIsolationForTests()

    private var acquired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !acquired {
            acquired = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            acquired = false
            return
        }

        waiters.removeFirst().resume()
    }
}

private actor CGSEventObserverIsolationForTests {
    static let shared = CGSEventObserverIsolationForTests()

    private var acquired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !acquired {
            acquired = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            acquired = false
            return
        }

        waiters.removeFirst().resume()
    }
}

@MainActor
func withAXFrameProviderIsolationForTests<T>(
    _ operation: @MainActor () async throws -> T
) async rethrows -> T {
    await AXFrameProviderIsolationForTests.shared.acquire()
    do {
        let result = try await operation()
        await AXFrameProviderIsolationForTests.shared.release()
        return result
    } catch {
        await AXFrameProviderIsolationForTests.shared.release()
        throw error
    }
}

@MainActor
func withCGSEventObserverIsolationForTests<T>(
    _ operation: @MainActor () async throws -> T
) async rethrows -> T {
    await CGSEventObserverIsolationForTests.shared.acquire()
    do {
        let result = try await operation()
        await CGSEventObserverIsolationForTests.shared.release()
        return result
    } catch {
        await CGSEventObserverIsolationForTests.shared.release()
        throw error
    }
}

private let testConfigurationDirectoryKey = "__omniwm.test.configurationDirectory"

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
func fallbackFastFrameForTests(_ window: AXWindowRef) -> CGRect? {
    guard let frame = SkyLight.shared.getWindowBounds(UInt32(AXWindowService.windowId(window))) else {
        return nil
    }
    return ScreenCoordinateSpace.toAppKit(rect: frame)
}

@MainActor
func resetSharedControllerStateForTests() {
    let contextFactory = AppAXContext.contextFactoryForTests
    let axWindowRefProvider = AXWindowService.axWindowRefProviderForTests
    let setFrameResultProvider = AXWindowService.setFrameResultProviderForTests
    let fastFrameProvider = AXWindowService.fastFrameProviderForTests
    let titleLookupProvider = AXWindowService.titleLookupProviderForTests
    let timeSource = AXWindowService.timeSourceForTests
    let orderedStateProvider = SkyLight.orderedStateProviderForTests

    SettingsWindowController.shared.windowForTests?.close()
    AppRulesWindowController.shared.windowForTests?.close()
    SponsorsWindowController.shared.windowForTests?.close()
    UpdateWindowController.shared.windowForTests?.close()
    OwnedWindowRegistry.shared.resetForTests()

    AppAXContext.contextFactoryForTests = contextFactory
    AXWindowService.axWindowRefProviderForTests = axWindowRefProvider
    AXWindowService.setFrameResultProviderForTests = setFrameResultProvider
    AXWindowService.fastFrameProviderForTests = fastFrameProvider
    AXWindowService.titleLookupProviderForTests = titleLookupProvider
    AXWindowService.timeSourceForTests = timeSource
    AXWindowService.clearTitleCacheForTests()
    AXWindowService.clearPinnedAXElementsForTests()
    SkyLight.orderedStateProviderForTests = orderedStateProvider
}
