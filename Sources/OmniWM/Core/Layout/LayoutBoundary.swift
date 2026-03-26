import AppKit
import Foundation

struct LayoutWindowSnapshot {
    let token: WindowToken
    let constraints: WindowSizeConstraints
    let hiddenState: WindowModel.HiddenState?
    let layoutReason: LayoutReason

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
}

struct NiriWindowRemovalSeed {
    let removedNodeIds: [NodeId]
    let oldFrames: [WindowToken: CGRect]
}

struct NiriWorkspaceSnapshot {
    let workspaceId: WorkspaceDescriptor.ID
    let monitor: LayoutMonitorSnapshot
    let windows: [LayoutWindowSnapshot]
    let viewportState: ViewportState
    let preferredFocusToken: WindowToken?
    let confirmedFocusedToken: WindowToken?
    let pendingFocusedToken: WindowToken?
    let pendingFocusedWorkspaceId: WorkspaceDescriptor.ID?
    let isNonManagedFocusActive: Bool
    let hasCompletedInitialRefresh: Bool
    let useScrollAnimationPath: Bool
    let removalSeed: NiriWindowRemovalSeed?
    let gap: CGFloat
    let outerGaps: LayoutGaps.OuterGaps
    let displayRefreshRate: Double
    let isActiveWorkspace: Bool
    let isInteractionWorkspace: Bool
}

struct DwindleWorkspaceSnapshot {
    let workspaceId: WorkspaceDescriptor.ID
    let monitor: LayoutMonitorSnapshot
    let windows: [LayoutWindowSnapshot]
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

enum BorderUpdateMode {
    case coordinated
    case direct
    case none
}

// `frameChanges` imply active, restore-eligible windows for this pass.
// `visibilityChanges` are reserved for explicit hide/show transitions.
struct WorkspaceLayoutDiff {
    var frameChanges: [LayoutFrameChange] = []
    var visibilityChanges: [LayoutVisibilityChange] = []
    var restoreChanges: [LayoutRestoreChange] = []
    var focusedFrame: LayoutFocusedFrame?
    var borderMode: BorderUpdateMode = .coordinated
}

struct WorkspaceSessionPatch {
    let workspaceId: WorkspaceDescriptor.ID
    var viewportState: ViewportState?
    var rememberedFocusToken: WindowToken?
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

struct RefreshVisibilityEffect {
    let activeWorkspaceIds: Set<WorkspaceDescriptor.ID>
}

struct RefreshExecutionEffects {
    var visibility: RefreshVisibilityEffect?
    var requestWorkspaceBarRefresh: Bool = false
    var updateTabbedOverlays: Bool = false
    var refreshFocusedBorderForVisibilityState: Bool = false
    var focusValidationWorkspaceIds: [WorkspaceDescriptor.ID] = []
    var markInitialRefreshComplete: Bool = false
    var drainDeferredCreatedWindows: Bool = false
    var subscribeManagedWindows: Bool = false
}

struct WorkspaceLayoutPlan {
    let workspaceId: WorkspaceDescriptor.ID
    let monitor: LayoutMonitorSnapshot
    var sessionPatch: WorkspaceSessionPatch
    var diff: WorkspaceLayoutDiff
    var animationDirectives: [AnimationDirective] = []
}

typealias RefreshPostLayoutAction = @MainActor () -> Void

struct RefreshExecutionPlan {
    var workspacePlans: [WorkspaceLayoutPlan] = []
    var effects: RefreshExecutionEffects = .init()
    var postLayoutActions: [RefreshPostLayoutAction] = []
}
