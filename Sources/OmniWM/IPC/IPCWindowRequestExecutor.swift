// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import OmniWMIPC

@MainActor
struct IPCWindowRequestExecutor {
    private let controller: WMController
    private let sessionToken: String

    init(controller: WMController, sessionToken: String) {
        self.controller = controller
        self.sessionToken = sessionToken
    }

    func handle(_ request: IPCWindowRequest) -> ExternalCommandResult {
        if let guardResult = IPCCommandValidation.controllerState(controller) {
            return guardResult
        }

        switch IPCWindowOpaqueID.validate(request.windowId, expectingSessionToken: sessionToken) {
        case .invalid:
            return .invalidArguments
        case .stale:
            return .staleWindowId
        case let .valid(pid, windowId):
            let token = WindowToken(pid: pid, windowId: windowId)
            switch request.name {
            case .focus:
                return controller.windowActionHandler.focusWindowFromBar(token: token)
                    ? .executed
                    : .notFound
            case .navigate:
                guard let handle = controller.workspaceManager.handle(for: token) else {
                    return .notFound
                }
                return controller.windowActionHandler.navigateToWindow(handle: handle)
                    ? .executed
                    : .notFound
            case .summonRight:
                guard let handle = controller.workspaceManager.handle(for: token) else {
                    return .notFound
                }
                return controller.windowActionHandler.summonWindowRight(handle: handle)
                    ? .executed
                    : .notFound
            case .close:
                guard let handle = controller.workspaceManager.handle(for: token) else { return .notFound }
                return controller.windowActionHandler.closeWindow(handle: handle) ? .executed : .windowActionFailed
            case .moveToWorkspace:
                guard let target = request.workspaceTarget else { return .invalidArguments }
                guard let handle = controller.workspaceManager.handle(for: token) else { return .notFound }
                return moveWindow(handle, to: target)
            }
        }
    }

    private func moveWindow(_ handle: WindowHandle, to target: WorkspaceTarget) -> ExternalCommandResult {
        let rawWorkspaceID: String
        switch IPCCommandValidation.workspaceTarget(target, controller: controller) {
        case let .failure(result):
            return result
        case let .success(resolved):
            rawWorkspaceID = resolved
        }
        guard let targetWorkspaceId = controller.workspaceManager.workspaceId(
            for: rawWorkspaceID,
            createIfMissing: false
        ) else { return .notFound }
        guard !IPCCommandValidation.isAlreadyOnWorkspace(
            handle.id,
            rawWorkspaceID: rawWorkspaceID,
            controller: controller
        ) else { return .noChange }
        if case .changed = controller.workspaceNavigationHandler.commitWindowMove(
            handle: handle,
            toWorkspaceId: targetWorkspaceId
        ) {
            return .executed
        }
        return .workspaceStateConflict
    }
}
