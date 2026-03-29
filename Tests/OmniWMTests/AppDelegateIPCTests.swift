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

@Suite @MainActor struct AppDelegateIPCTests {
    @Test func finishBootstrapStartsIPCOnlyAfterStatusBarSetup() {
        let defaults = makeLayoutPlanTestDefaults()
        SettingsStore(defaults: defaults).ipcEnabled = true
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
            bootstrappedController?.statusBarController?.cleanup()
        }

        let appDelegate = AppDelegate()
        appDelegate.finishBootstrap(defaults: defaults)

        #expect(observedControllerStatusBar)
        #expect(observedImagePosition != nil)
    }

    @Test func finishBootstrapLeavesIPCStoppedWhenDisabledByDefault() {
        let defaults = makeLayoutPlanTestDefaults()
        var observedStart = false
        AppDelegate.ipcServerFactoryForTests = { _ in
            TestIPCServer {
                observedStart = true
            }
        }
        defer {
            AppDelegate.ipcServerFactoryForTests = nil
        }

        let appDelegate = AppDelegate()
        appDelegate.finishBootstrap(defaults: defaults)

        #expect(observedStart == false)
    }

    @Test func finishBootstrapMakesIPCReachableAndTerminateUnlinksSocket() async throws {
        let defaults = makeLayoutPlanTestDefaults()
        SettingsStore(defaults: defaults).ipcEnabled = true
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
            bootstrappedController?.statusBarController?.cleanup()
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let appDelegate = AppDelegate()
        #expect(!FileManager.default.fileExists(atPath: socketPath))

        appDelegate.finishBootstrap(defaults: defaults)

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
}
