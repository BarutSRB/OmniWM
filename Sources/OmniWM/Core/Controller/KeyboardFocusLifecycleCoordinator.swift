import Foundation

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

enum ManagedFocusOrigin: Equatable {
    case keyboardOrProgrammatic
    case pointerHover

    var allowsMouseToFocusedWarp: Bool {
        self == .keyboardOrProgrammatic
    }

    func merged(with origin: ManagedFocusOrigin) -> ManagedFocusOrigin {
        if self == .keyboardOrProgrammatic || origin == .keyboardOrProgrammatic {
            return .keyboardOrProgrammatic
        }
        return .pointerHover
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
    var origin: ManagedFocusOrigin
    var retryCount: Int = 0
    var lastActivationSource: ActivationEventSource?
    var status: Status = .pending
}

private struct FocusOperation: Equatable {
    var token: WindowToken
    var origin: ManagedFocusOrigin
}

@MainActor
final class FocusBridgeCoordinator {
    static let activationSettleDeadline: Duration = .milliseconds(100)

    private let intentLedger: IntentLedger
    private let deadlineWheel: DeadlineWheel
    private(set) var activeManagedRequest: ManagedFocusRequest?
    private var nextRequestId: UInt64 = 1
    private var pendingFocus: FocusOperation?
    private var deferredFocus: FocusOperation?
    private var lastConfirmedManagedFocus: FocusOperation?
    private var isFocusOperationPending = false
    private var lastFocusTime: Date = .distantPast

    init(intentLedger: IntentLedger, deadlineWheel: DeadlineWheel) {
        self.intentLedger = intentLedger
        self.deadlineWheel = deadlineWheel
    }

    func beginManagedRequest(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        origin: ManagedFocusOrigin = .keyboardOrProgrammatic
    ) -> ManagedFocusRequest {
        if var activeManagedRequest,
           activeManagedRequest.token == token,
           activeManagedRequest.workspaceId == workspaceId
        {
            let mergedOrigin = activeManagedRequest.origin.merged(with: origin)
            if activeManagedRequest.origin != mergedOrigin {
                activeManagedRequest.origin = mergedOrigin
                self.activeManagedRequest = activeManagedRequest
            }
            _ = intentLedger.registerFocusWindow(
                token: token,
                workspaceId: workspaceId,
                origin: origin,
                correlatedRequestId: activeManagedRequest.requestId
            )
            return activeManagedRequest
        }

        if let replacedRequest = activeManagedRequest {
            retireIntent(correlatedRequestId: replacedRequest.requestId) {
                intentLedger.supersede(id: $0)
            }
        }

        let request = ManagedFocusRequest(
            requestId: nextRequestId,
            token: token,
            workspaceId: workspaceId,
            origin: origin
        )
        nextRequestId += 1
        activeManagedRequest = request
        let intent = intentLedger.registerFocusWindow(
            token: token,
            workspaceId: workspaceId,
            origin: origin,
            correlatedRequestId: request.requestId
        )
        deadlineWheel.schedule(intentId: intent.id, after: Self.activationSettleDeadline)
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

    func allowsMouseToFocusedWarp(for token: WindowToken) -> Bool {
        if let activeManagedRequest, activeManagedRequest.token == token {
            return activeManagedRequest.origin.allowsMouseToFocusedWarp
        }
        if let lastConfirmedManagedFocus, lastConfirmedManagedFocus.token == token {
            return lastConfirmedManagedFocus.origin.allowsMouseToFocusedWarp
        }
        return true
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
        if let intent = intentLedger.openFocusIntent(correlatedRequestId: requestId) {
            _ = intentLedger.recordRetry(id: intent.id, source: source)
            deadlineWheel.schedule(intentId: intent.id, after: Self.activationSettleDeadline)
        }
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

        activeManagedRequest.lastActivationSource = source
        activeManagedRequest.status = .confirmed
        lastConfirmedManagedFocus = FocusOperation(
            token: activeManagedRequest.token,
            origin: activeManagedRequest.origin
        )
        self.activeManagedRequest = nil
        retireIntent(correlatedRequestId: activeManagedRequest.requestId) {
            intentLedger.confirm(id: $0, source: source)
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
        retireIntent(correlatedRequestId: activeManagedRequest.requestId) {
            intentLedger.cancel(id: $0)
        }
        return activeManagedRequest
    }

    @discardableResult
    func cancelManagedRequest(requestId: UInt64) -> ManagedFocusRequest? {
        guard let activeManagedRequest, activeManagedRequest.requestId == requestId else {
            return nil
        }
        self.activeManagedRequest = nil
        retireIntent(correlatedRequestId: requestId) {
            intentLedger.cancel(id: $0)
        }
        return activeManagedRequest
    }

    func rekeyManagedRequest(from oldToken: WindowToken, to newToken: WindowToken) {
        if var activeManagedRequest, activeManagedRequest.token == oldToken {
            activeManagedRequest.token = newToken
            self.activeManagedRequest = activeManagedRequest
        }
        if var lastConfirmedManagedFocus, lastConfirmedManagedFocus.token == oldToken {
            lastConfirmedManagedFocus.token = newToken
            self.lastConfirmedManagedFocus = lastConfirmedManagedFocus
        }
        intentLedger.rekey(from: oldToken, to: newToken)
    }

    private func retireIntent(
        correlatedRequestId: UInt64,
        _ retire: (IntentID) -> Intent?
    ) {
        guard let intent = intentLedger.openFocusIntent(correlatedRequestId: correlatedRequestId) else { return }
        _ = retire(intent.id)
        deadlineWheel.cancel(intentId: intent.id)
    }

    func discardPendingFocus(_ token: WindowToken) {
        if pendingFocus?.token == token {
            pendingFocus = nil
        }
        if deferredFocus?.token == token {
            deferredFocus = nil
        }
        if lastConfirmedManagedFocus?.token == token {
            lastConfirmedManagedFocus = nil
        }
    }

    func rekeyPendingFocus(from oldToken: WindowToken, to newToken: WindowToken) {
        if var pendingFocus, pendingFocus.token == oldToken {
            pendingFocus.token = newToken
            self.pendingFocus = pendingFocus
        }
        if var deferredFocus, deferredFocus.token == oldToken {
            deferredFocus.token = newToken
            self.deferredFocus = deferredFocus
        }
    }

    func focusWindow(
        _ token: WindowToken,
        origin: ManagedFocusOrigin,
        performFocus: () -> Void,
        onDeferredFocus: @escaping (WindowToken, ManagedFocusOrigin) -> Void
    ) {
        let now = Date()
        let operation = FocusOperation(token: token, origin: origin)

        if pendingFocus?.token == token, now.timeIntervalSince(lastFocusTime) < 0.016 {
            return
        }

        if isFocusOperationPending {
            if var deferredFocus, deferredFocus.token == token {
                deferredFocus.origin = deferredFocus.origin.merged(with: origin)
                self.deferredFocus = deferredFocus
            } else {
                deferredFocus = operation
            }
            return
        }

        isFocusOperationPending = true
        pendingFocus = operation
        lastFocusTime = now

        performFocus()

        isFocusOperationPending = false
        if let deferredFocus, deferredFocus.token != token {
            self.deferredFocus = nil
            onDeferredFocus(deferredFocus.token, deferredFocus.origin)
        }
    }

    func reset() {
        activeManagedRequest = nil
        nextRequestId = 1
        pendingFocus = nil
        deferredFocus = nil
        lastConfirmedManagedFocus = nil
        isFocusOperationPending = false
        lastFocusTime = .distantPast
    }
}
