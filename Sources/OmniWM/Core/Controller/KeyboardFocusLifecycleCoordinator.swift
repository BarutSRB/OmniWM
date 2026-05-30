import Foundation
import os

struct KeyboardFocusTarget {
    let token: WindowToken
    let axRef: AXWindowRef
    let workspaceId: WorkspaceDescriptor.ID?
    let isManaged: Bool

    var pid: pid_t {
        token.pid
    }

    var windowId: Int {
        token.windowId
    }
}

extension KeyboardFocusTarget: Equatable {
    static func == (lhs: KeyboardFocusTarget, rhs: KeyboardFocusTarget) -> Bool {
        lhs.token == rhs.token
            && lhs.workspaceId == rhs.workspaceId
            && lhs.isManaged == rhs.isManaged
    }
}

struct ManagedFocusRequest: Equatable {
    enum Status: Equatable {
        case pending
        case confirmed
    }

    let requestId: UInt64
    var token: WindowToken
    var workspaceId: WorkspaceDescriptor.ID
    var retryCount: Int = 0
    var lastActivationSource: ActivationEventSource?
    var status: Status = .pending
}

@MainActor
final class FocusBridgeCoordinator {
    private(set) var activeManagedRequest: ManagedFocusRequest?
    private var nextRequestId: UInt64 = 1
    private var pendingFocusToken: WindowToken?
    private var deferredFocusToken: WindowToken?
    private var isFocusOperationPending = false
    private var lastFocusTime: Date = .distantPast

    func beginManagedRequest(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> ManagedFocusRequest {
        if let activeManagedRequest,
           activeManagedRequest.token == token,
           activeManagedRequest.workspaceId == workspaceId
        {
            return activeManagedRequest
        }

        WMLog.focus.debug("Focus request begin")
        let request = ManagedFocusRequest(
            requestId: nextRequestId,
            token: token,
            workspaceId: workspaceId
        )
        nextRequestId += 1
        activeManagedRequest = request
        return request
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

    func recordRetry(
        requestId: UInt64,
        source: ActivationEventSource,
        retryLimit: Int
    ) -> ManagedFocusRequest? {
        guard var activeManagedRequest, activeManagedRequest.requestId == requestId else {
            return nil
        }

        let retryCount = activeManagedRequest.lastActivationSource == source
            ? activeManagedRequest.retryCount
            : 0
        let nextAttempt = retryCount + 1
        guard nextAttempt <= retryLimit else { return nil }

        activeManagedRequest.retryCount = nextAttempt
        activeManagedRequest.lastActivationSource = source
        self.activeManagedRequest = activeManagedRequest
        return activeManagedRequest
    }

    @discardableResult
    func confirmManagedRequest(
        token: WindowToken,
        source: ActivationEventSource
    ) -> ManagedFocusRequest? {
        guard var activeManagedRequest, activeManagedRequest.token == token else {
            return nil
        }

        WMLog.focus.debug("Focus request confirmed")
        activeManagedRequest.lastActivationSource = source
        activeManagedRequest.status = .confirmed
        self.activeManagedRequest = nil
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

    func reset() {
        activeManagedRequest = nil
        nextRequestId = 1
        pendingFocusToken = nil
        deferredFocusToken = nil
        isFocusOperationPending = false
        lastFocusTime = .distantPast
    }
}
