// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Foundation
@testable import OmniWM

@MainActor
enum WindowAdmissionTestSupport {
    static func controller(prefix: String = "OmniWMWindowAdmissionTests") -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        return WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
    }

    static func workspace(
        named name: String,
        layoutType: LayoutType,
        controller: WMController
    ) -> WorkspaceDescriptor.ID? {
        controller.settings.workspaceConfigurations.append(
            WorkspaceConfiguration(name: name, layoutType: layoutType)
        )
        controller.workspaceManager.applySettings()
        return controller.workspaceManager.workspaceId(for: name, createIfMissing: true)
    }

    static func drainLayoutRefreshes(_ controller: WMController) async {
        while true {
            if let task = controller.layoutRefreshController.layoutState.activeRefreshTask {
                await task.value
                continue
            }
            if controller.layoutRefreshController.layoutState.pendingRefresh == nil {
                return
            }
            await Task.yield()
        }
    }

    static func axRef(for token: WindowToken) -> AXWindowRef {
        AXWindowRef(
            element: AXUIElementCreateApplication(token.pid),
            windowId: token.windowId
        )
    }

    static func track(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) -> AXWindowRef {
        let axRef = axRef(for: token)
        _ = controller.workspaceManager.addWindow(
            axRef,
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId
        )
        return axRef
    }

    static func frameRequest(
        _ ledger: AXFrameApplicationLedger,
        pid: pid_t,
        windowId: Int,
        frame: CGRect,
        isRetry: Bool = false
    ) -> AXFrameApplicationRequest? {
        ledger.prepareFrameApplication(
            pid: pid,
            windowId: windowId,
            frame: frame,
            isRetry: isRetry,
            terminalObserver: nil
        ).request
    }

    static func frameResult(
        request: AXFrameApplicationRequest,
        observed: CGRect,
        failure: AXFrameWriteFailureReason
    ) -> AXFrameApplyResult {
        AXFrameApplyResult(
            requestId: request.requestId,
            pid: request.pid,
            windowId: request.windowId,
            targetFrame: request.frame,
            currentFrameHint: request.currentFrameHint,
            writeResult: AXFrameWriteResult(
                targetFrame: request.frame,
                observedFrame: observed,
                writeOrder: .sizeThenPosition,
                sizeError: .attributeUnsupported,
                positionError: .success,
                failureReason: failure
            )
        )
    }

    static func successfulFrameResult(request: AXFrameApplicationRequest) -> AXFrameApplyResult {
        AXFrameApplyResult(
            requestId: request.requestId,
            pid: request.pid,
            windowId: request.windowId,
            targetFrame: request.frame,
            currentFrameHint: request.currentFrameHint,
            writeResult: AXFrameWriteResult(
                targetFrame: request.frame,
                observedFrame: request.frame,
                writeOrder: .sizeThenPosition,
                sizeError: .success,
                positionError: .success,
                failureReason: nil
            )
        )
    }
}
