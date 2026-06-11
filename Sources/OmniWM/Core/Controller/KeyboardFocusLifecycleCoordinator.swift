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
