// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation
import Testing

import OmniWMIPC
@testable import OmniWM
@testable import OmniWMCtl

private func makeAppDelegateIPCTestSocketPath() -> String {
    "/tmp/owm-ad-\(UUID().uuidString.prefix(8)).sock"
}

@MainActor
private final class TestIPCServer: IPCServerLifecycle {
    private let onStart: @MainActor () -> Void

    init(onStart: @escaping @MainActor () -> Void) {
        self.onStart = onStart
    }

    func start() throws {
        onStart()
    }

    func stop() {}
}

@MainActor
private final class TestUpdateCoordinator: AppUpdateCoordinating {
    private let onStart: @MainActor () -> Void

    init(onStart: @escaping @MainActor () -> Void = {}) {
        self.onStart = onStart
    }

    func startAutomaticChecks() {
        onStart()
    }

    func checkForUpdatesManually() {}
}

@Suite(.serialized) @MainActor struct AppDelegateIPCTests {
    @Test func finishBootstrapStartsIPCOnlyAfterStatusBarSetup() {
        let defaults = makeLayoutPlanTestDefaults()
        SettingsStore(defaults: defaults).ipcEnabled = true
        let configurationDirectory = configurationDirectoryForTests(defaults: defaults)
        var bootstrappedController: WMController?
        var observedControllerStatusBar = false
        var observedImagePosition: NSControl.ImagePosition?
        AppDelegate.ipcServerFactoryForTests = { controller in
            bootstrappedController = controller
            return TestIPCServer {
                observedControllerStatusBar = controller.statusBarController != nil
                observedImagePosition = controller.statusBarController?.statusButtonImagePositionForTests()
            }
        }
        defer {
            AppDelegate.ipcServerFactoryForTests = nil
            AppDelegate.runtimeFactoryForTests = nil
            AppDelegate.updateCoordinatorFactoryForTests = nil
            bootstrappedController?.statusBarController?.cleanup()
        }

        let appDelegate = AppDelegate()
        appDelegate.finishBootstrap(configurationDirectory: configurationDirectory)

        #expect(observedControllerStatusBar)
        #expect(observedImagePosition != nil)
    }

    @Test func finishBootstrapLeavesIPCStoppedWhenDisabledByDefault() {
        let defaults = makeLayoutPlanTestDefaults()
        let configurationDirectory = configurationDirectoryForTests(defaults: defaults)
        var observedStart = false
        AppDelegate.ipcServerFactoryForTests = { _ in
            TestIPCServer {
                observedStart = true
            }
        }
        defer {
            AppDelegate.ipcServerFactoryForTests = nil
            AppDelegate.runtimeFactoryForTests = nil
            AppDelegate.updateCoordinatorFactoryForTests = nil
        }

        let appDelegate = AppDelegate()
        appDelegate.finishBootstrap(configurationDirectory: configurationDirectory)

        #expect(observedStart == false)
    }

    @Test func finishBootstrapStartsUpdateChecksOnlyAfterStatusBarSetup() {
        let defaults = makeLayoutPlanTestDefaults()
        let configurationDirectory = configurationDirectoryForTests(defaults: defaults)
        var observedControllerStatusBar = false
        var bootstrappedController: WMController?
        AppDelegate.updateCoordinatorFactoryForTests = { _, controller, _ in
            bootstrappedController = controller
            return TestUpdateCoordinator {
                observedControllerStatusBar = controller.statusBarController != nil
            }
        }
        defer {
            AppDelegate.runtimeFactoryForTests = nil
            AppDelegate.updateCoordinatorFactoryForTests = nil
            bootstrappedController?.statusBarController?.cleanup()
        }

        let appDelegate = AppDelegate()
        appDelegate.finishBootstrap(configurationDirectory: configurationDirectory)

        #expect(observedControllerStatusBar)
    }

    @Test func finishBootstrapMakesIPCReachableAndTerminateUnlinksSocket() async throws {
        let defaults = makeLayoutPlanTestDefaults()
        SettingsStore(defaults: defaults).ipcEnabled = true
        let configurationDirectory = configurationDirectoryForTests(defaults: defaults)
        let socketPath = makeAppDelegateIPCTestSocketPath()
        var bootstrappedController: WMController?
        AppDelegate.ipcServerFactoryForTests = { controller in
            bootstrappedController = controller
            return IPCServer(
                controller: controller,
                socketPath: socketPath,
                sessionToken: "app-delegate-ipc-tests"
            )
        }
        defer {
            AppDelegate.ipcServerFactoryForTests = nil
            AppDelegate.runtimeFactoryForTests = nil
            AppDelegate.updateCoordinatorFactoryForTests = nil
            bootstrappedController?.statusBarController?.cleanup()
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let appDelegate = AppDelegate()
        #expect(!FileManager.default.fileExists(atPath: socketPath))

        appDelegate.finishBootstrap(configurationDirectory: configurationDirectory)

        #expect(FileManager.default.fileExists(atPath: socketPath))

        let client = IPCClient(socketPath: socketPath)
        let connection = try client.openConnection()
        defer {
            Task {
                await connection.close()
            }
        }

        try await connection.send(IPCRequest(id: "ping-after-bootstrap", kind: .ping))
        let response = try await connection.readResponse()

        #expect(response.ok)
        #expect(response.kind == .ping)
        #expect(response.result?.kind == .pong)

        appDelegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    @Test func applicationWillTerminateStopsRuntimeServices() throws {
        let defaults = makeLayoutPlanTestDefaults()
        let configurationDirectory = configurationDirectoryForTests(defaults: defaults)
        var bootstrappedController: WMController?
        AppDelegate.runtimeFactoryForTests = { settings in
            let runtime = WMRuntime(settings: settings)
            runtime.controller.serviceLifecycleManager.accessibilityPermissionStateProviderForTests = { false }
            bootstrappedController = runtime.controller
            return runtime
        }
        AppDelegate.updateCoordinatorFactoryForTests = { _, _, _ in
            TestUpdateCoordinator()
        }
        defer {
            AppDelegate.runtimeFactoryForTests = nil
            AppDelegate.updateCoordinatorFactoryForTests = nil
            bootstrappedController?.statusBarController?.cleanup()
        }

        let appDelegate = AppDelegate()
        appDelegate.finishBootstrap(configurationDirectory: configurationDirectory)
        let controller = try #require(bootstrappedController)
        controller.hasStartedServices = true

        appDelegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        #expect(controller.hasStartedServices == false)
    }

}
