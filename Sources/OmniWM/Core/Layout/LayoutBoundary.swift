import AppKit
import Foundation

struct LayoutWindowSnapshot {
    let token: WindowToken
    let constraints: WindowSizeConstraints
    let layoutConstraints: WindowSizeConstraints
    let hiddenState: WindowModel.HiddenState?
    let layoutReason: LayoutReason
    let showsNativeFullscreenPlaceholder: Bool

    var isNativeFullscreenSuspended: Bool {
        layoutReason == .nativeFullscreen
    }
}

struct LayoutMonitorSnapshot {
    let monitorId: Monitor.ID
    let displayId: CGDirectDisplayID
    let frame: CGRect
    let visibleFrame: CGRect
    let workingFrame: CGRect
    let scale: CGFloat
    let orientation: Monitor.Orientation
}

struct WorkspaceRefreshInput {
    let workspaceId: WorkspaceDescriptor.ID
    let monitor: LayoutMonitorSnapshot
    let windows: [LayoutWindowSnapshot]
    let isActiveWorkspace: Bool
    let runtimeRevision: RuntimeRevision
}

struct NiriWindowRemovalSeed {
    let removedNodeIds: [NodeId]
    let oldFrames: [WindowToken: CGRect]
}

struct NiriWorkspaceSnapshot {
    let workspaceId: WorkspaceDescriptor.ID
    let monitor: LayoutMonitorSnapshot
    let windows: [LayoutWindowSnapshot]
    let runtimeRevision: RuntimeRevision
    let viewportState: ViewportState
    let preferredFocusToken: WindowToken?
    let confirmedFocusedToken: WindowToken?
    let pendingFocusedToken: WindowToken?
    let hasCompletedInitialRefresh: Bool
    let useScrollAnimationPath: Bool
    let removalSeed: NiriWindowRemovalSeed?
    let gap: CGFloat
    let outerGaps: LayoutGaps.OuterGaps
    let displayRefreshRate: Double
    let isActiveWorkspace: Bool
}

struct DwindleWorkspaceSnapshot {
    let workspaceId: WorkspaceDescriptor.ID
    let monitor: LayoutMonitorSnapshot
    let windows: [LayoutWindowSnapshot]
    let runtimeRevision: RuntimeRevision
    let preferredFocusToken: WindowToken?
    let confirmedFocusedToken: WindowToken?
    let selectedToken: WindowToken?
    let settings: ResolvedDwindleSettings
    let isActiveWorkspace: Bool
}

struct LayoutFrameChange {
    let token: WindowToken
    let frame: CGRect
    let forceApply: Bool
}

struct LayoutRestoreChange {
    let token: WindowToken
    let hiddenState: WindowModel.HiddenState
}

enum LayoutVisibilityChange {
    case show(WindowToken)
    case hide(WindowToken, side: HideSide)
}

struct LayoutFocusedFrame {
    let token: WindowToken
    let frame: CGRect
}

struct NativeFullscreenPlaceholderChange {
    let token: WindowToken
    let frame: CGRect
    let selected: Bool
}

// `frameChanges` imply active, restore-eligible windows for this pass.
// `visibilityChanges` are reserved for explicit hide/show transitions.
struct WorkspaceLayoutDiff {
    var frameChanges: [LayoutFrameChange] = []
    var visibilityChanges: [LayoutVisibilityChange] = []
    var restoreChanges: [LayoutRestoreChange] = []
    var nativeFullscreenPlaceholders: [NativeFullscreenPlaceholderChange] = []
    var focusedFrame: LayoutFocusedFrame?
}

struct WorkspaceSessionPatch {
    let workspaceId: WorkspaceDescriptor.ID
    var viewportState: ViewportState?
    var rememberedFocusToken: WindowToken?
    var baseSelectionRevision: UInt64? = nil
    var runtimeRevision: RuntimeRevision
}

struct WorkspaceSessionTransfer {
    var sourcePatch: WorkspaceSessionPatch?
    var targetPatch: WorkspaceSessionPatch?
}

enum AnimationDirective {
    case none
    case startNiriScroll(workspaceId: WorkspaceDescriptor.ID)
    case startDwindleAnimation(workspaceId: WorkspaceDescriptor.ID, monitorId: Monitor.ID)
    case activateWindow(token: WindowToken)
    case updateTabbedOverlays
}

struct RefreshVisibilityEffect: Equatable {}

struct RefreshExecutionEffects {
    var visibility: RefreshVisibilityEffect?
    var requestWorkspaceBarRefresh: Bool = false
    var updateTabbedOverlays: Bool = false
    var refreshFocusedBorderForVisibilityState: Bool = false
    var focusValidationWorkspaceIds: [WorkspaceDescriptor.ID] = []
    var focusValidationPreferredTokens: [WorkspaceDescriptor.ID: WindowToken] = [:]
    var markInitialRefreshComplete: Bool = false
    var drainDeferredCreatedWindows: Bool = false
    var subscribeManagedWindows: Bool = false
}

struct WorkspaceLayoutPlan {
    let workspaceId: WorkspaceDescriptor.ID
    let monitor: LayoutMonitorSnapshot
    var runtimeRevision: RuntimeRevision
    var sessionPatch: WorkspaceSessionPatch
    var diff: WorkspaceLayoutDiff
    var niriRestorePlacements: [WindowToken: PersistedNiriPlacement] = [:]
    var animationDirectives: [AnimationDirective] = []
}

struct RefreshPostLayoutAction {
    let workspaceRevisions: [WorkspaceDescriptor.ID: RuntimeRevision]
    let domains: RuntimeRevisionDomain
    private let action: @MainActor () -> Void

    init(
        workspaceRevisions: [WorkspaceDescriptor.ID: RuntimeRevision] = [:],
        domains: RuntimeRevisionDomain = [.workspace, .layout, .focus, .fullscreen],
        action: @escaping @MainActor () -> Void
    ) {
        self.workspaceRevisions = workspaceRevisions
        self.domains = domains
        self.action = action
    }

    @MainActor
    func isCurrent(using workspaceManager: WorkspaceManager) -> Bool {
        for (workspaceId, revision) in workspaceRevisions {
            guard workspaceManager.isRuntimeRevisionCurrent(
                revision,
                for: workspaceId,
                domains: domains
            ) else {
                return false
            }
        }
        return true
    }

    func hasWorkspace(in workspaceIds: Set<WorkspaceDescriptor.ID>) -> Bool {
        guard !workspaceRevisions.isEmpty else { return false }
        for workspaceId in workspaceRevisions.keys where workspaceIds.contains(workspaceId) {
            return true
        }
        return false
    }

    func refreshingAcceptedRevisions(
        _ acceptedRevisions: [WorkspaceDescriptor.ID: AcceptedRuntimeRevision]
    ) -> RefreshPostLayoutAction {
        var revisions = workspaceRevisions
        var changed = false
        for (workspaceId, revision) in workspaceRevisions {
            guard let accepted = acceptedRevisions[workspaceId],
                  accepted.domains.intersection(domains) == domains,
                  revision.matches(accepted.before, domains: domains)
            else {
                continue
            }
            revisions[workspaceId] = accepted.after
            changed = true
        }
        guard changed else { return self }
        return RefreshPostLayoutAction(
            workspaceRevisions: revisions,
            domains: domains,
            action: action
        )
    }

    @MainActor
    func runIfCurrent(using workspaceManager: WorkspaceManager) {
        guard isCurrent(using: workspaceManager) else { return }
        action()
    }
}

struct AcceptedRuntimeRevision {
    let before: RuntimeRevision
    let after: RuntimeRevision
    let domains: RuntimeRevisionDomain
}

struct RefreshExecutionPlan {
    var workspacePlans: [WorkspaceLayoutPlan] = []
    var effects: RefreshExecutionEffects = .init()
    var postLayoutActions: [RefreshPostLayoutAction] = []
}
