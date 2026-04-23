// SPDX-License-Identifier: GPL-2.0-only
import Foundation

struct KeyboardFocusTarget {
    let token: WindowToken
    let axRef: AXWindowRef
    let workspaceId: WorkspaceDescriptor.ID?
    let isManaged: Bool

    var pid: pid_t { token.pid }
    var windowId: Int { token.windowId }
}

extension KeyboardFocusTarget: Equatable {
    static func == (lhs: KeyboardFocusTarget, rhs: KeyboardFocusTarget) -> Bool {
        lhs.token == rhs.token
            && lhs.workspaceId == rhs.workspaceId
            && lhs.isManaged == rhs.isManaged
    }
}

extension KeyboardFocusTarget: CustomStringConvertible {
    var description: String {
        if isManaged {
            return "token=\(token)"
        }
        return "pid=\(pid) wid=\(windowId)"
    }
}

struct ManagedFocusRequest: Equatable {
    let requestId: UInt64
    var token: WindowToken
    var workspaceId: WorkspaceDescriptor.ID
    var retryCount: Int = 0
    var lastActivationSource: ActivationEventSource?
}

@MainActor
final class FocusBridgeCoordinator {
    private(set) var focusedTarget: KeyboardFocusTarget?
    private(set) var activeManagedRequest: ManagedFocusRequest?
    private var nextRequestId: UInt64 = 1
    private var pendingFocusToken: WindowToken?
    private var deferredFocusToken: WindowToken?
    private var isFocusOperationPending = false
    private var lastFocusTime: Date = .distantPast

    var nextManagedRequestId: UInt64 {
        nextRequestId
    }

    func applyOrchestrationState(
        nextManagedRequestId: UInt64,
        activeManagedRequest: ManagedFocusRequest?
    ) {
        nextRequestId = nextManagedRequestId
        self.activeManagedRequest = activeManagedRequest
    }

    func activeManagedRequest(for pid: pid_t) -> ManagedFocusRequest? {
        guard let activeManagedRequest, activeManagedRequest.token.pid == pid else {
            return nil
        }
        return activeManagedRequest
    }

    func activeManagedRequest(for token: WindowToken) -> ManagedFocusRequest? {
        guard let activeManagedRequest, activeManagedRequest.token == token else {
            return nil
        }
        return activeManagedRequest
    }

    func activeManagedRequest(requestId: UInt64) -> ManagedFocusRequest? {
        guard let activeManagedRequest, activeManagedRequest.requestId == requestId else {
            return nil
        }
        return activeManagedRequest
    }

    @discardableResult
    func cancelManagedRequest(
        matching token: WindowToken? = nil,
        workspaceId: WorkspaceDescriptor.ID? = nil
    ) -> ManagedFocusRequest? {
        guard let activeManagedRequest else { return nil }

        let matchesToken = token.map { activeManagedRequest.token == $0 } ?? true
        let matchesWorkspace = workspaceId.map { activeManagedRequest.workspaceId == $0 } ?? true
        guard matchesToken, matchesWorkspace else { return nil }

        self.activeManagedRequest = nil
        return activeManagedRequest
    }

    @discardableResult
    func cancelManagedRequest(requestId: UInt64) -> ManagedFocusRequest? {
        guard let activeManagedRequest, activeManagedRequest.requestId == requestId else {
            return nil
        }
        self.activeManagedRequest = nil
        return activeManagedRequest
    }

    func rekeyManagedRequest(from oldToken: WindowToken, to newToken: WindowToken) {
        guard var activeManagedRequest, activeManagedRequest.token == oldToken else {
            return
        }
        activeManagedRequest.token = newToken
        self.activeManagedRequest = activeManagedRequest
    }

    func discardPendingFocus(_ token: WindowToken) {
        if pendingFocusToken == token {
            pendingFocusToken = nil
        }
        if deferredFocusToken == token {
            deferredFocusToken = nil
        }
    }

    func rekeyPendingFocus(from oldToken: WindowToken, to newToken: WindowToken) {
        if pendingFocusToken == oldToken {
            pendingFocusToken = newToken
        }
        if deferredFocusToken == oldToken {
            deferredFocusToken = newToken
        }
    }

    func focusWindow(
        _ token: WindowToken,
        performFocus: () -> Void,
        onDeferredFocus: @escaping (WindowToken) -> Void
    ) {
        let now = Date()

        if pendingFocusToken == token, now.timeIntervalSince(lastFocusTime) < 0.016 {
            return
        }

        if isFocusOperationPending {
            deferredFocusToken = token
            return
        }

        isFocusOperationPending = true
        pendingFocusToken = token
        lastFocusTime = now

        performFocus()

        isFocusOperationPending = false
        if let deferred = deferredFocusToken, deferred != token {
            deferredFocusToken = nil
            onDeferredFocus(deferred)
        }
    }

    func setFocusedTarget(_ target: KeyboardFocusTarget?) {
        focusedTarget = target
    }

    func clearFocusedTarget(
        matching token: WindowToken? = nil,
        pid: pid_t? = nil
    ) {
        guard let focusedTarget else { return }

        let matchesToken = token.map { focusedTarget.token == $0 } ?? true
        let matchesPid = pid.map { focusedTarget.pid == $0 } ?? true
        guard matchesToken, matchesPid else { return }

        self.focusedTarget = nil
    }

    func rekeyFocusedTarget(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        axRef: AXWindowRef,
        workspaceId: WorkspaceDescriptor.ID?
    ) {
        guard let focusedTarget, focusedTarget.token == oldToken else { return }
        self.focusedTarget = KeyboardFocusTarget(
            token: newToken,
            axRef: axRef,
            workspaceId: workspaceId,
            isManaged: workspaceId != nil
        )
    }

    func updateFocusedTargetWorkspace(
        matching token: WindowToken,
        axRef: AXWindowRef,
        workspaceId: WorkspaceDescriptor.ID?
    ) {
        guard let focusedTarget, focusedTarget.token == token else { return }

        self.focusedTarget = KeyboardFocusTarget(
            token: token,
            axRef: axRef,
            workspaceId: workspaceId,
            isManaged: workspaceId != nil
        )
    }

    func reset() {
        focusedTarget = nil
        activeManagedRequest = nil
        nextRequestId = 1
        pendingFocusToken = nil
        deferredFocusToken = nil
        isFocusOperationPending = false
        lastFocusTime = .distantPast
    }
}
