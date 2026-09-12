// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Carbon
import Foundation
import QuartzCore
import ScreenCaptureKit

@MainActor
final class OverviewController {
    private weak var wmController: WMController?
    private let motionPolicy: MotionPolicy
    private let environment: OverviewEnvironment

    private(set) var state: OverviewState = .closed
    private let overviewSnapshot: OverviewSnapshot
    let drag: OverviewDragSession
    private let mutationSession: OverviewMutationSession
    private let structuralActions: OverviewStructuralActions
    private let projection: OverviewViewportProjection
    var selectedWindowHandle: WindowHandle? {
        projection.selectedWindowHandle
    }

    var activeInteractionMonitorId: Monitor.ID? {
        projection.activeInteractionMonitorId
    }

    private var presentation: OverviewPresentation

    private let thumbnailCapture: OverviewThumbnailCapture
    var thumbnailCache: [Int: CGImage] {
        thumbnailCapture.thumbnailCache
    }

    private let windowSession: OverviewWindowSession
    private var animator: OverviewAnimator?

    private let focusSession: OverviewFocusSession
    private let inputSession: OverviewInputSession
    let input: OverviewInputHandler

    var canPerformStructuralHotkey: Bool {
        !mutationSession.isTransferring
    }

    var onActivateWindow: ((WindowHandle, WorkspaceDescriptor.ID) -> Void)?
    var onCloseWindow: ((WindowHandle) -> Bool)?
    var isOpen: Bool {
        state.isOpen
    }

    init(
        wmController: WMController,
        motionPolicy: MotionPolicy,
        environment: OverviewEnvironment = .init(),
        ownedWindowRegistry: OwnedWindowRegistry = .shared,
        displayLinkFactory: @escaping OverviewAnimator.DisplayLinkFactory = OverviewAnimator.makeLiveDisplayLink,
        animationMediaTimeProvider: @escaping OverviewAnimator.MediaTimeProvider = CACurrentMediaTime
    ) {
        let presentation = OverviewPresentation(settings: wmController.settings)
        self.presentation = presentation
        let windowFacts = OverviewWindowFacts(wmController: wmController, environment: environment)
        let structuralActions = OverviewStructuralActions(wmController: wmController, windowFacts: windowFacts)
        self.structuralActions = structuralActions
        let overviewSnapshot = OverviewSnapshot(wmController: wmController, facts: windowFacts)
        self.overviewSnapshot = overviewSnapshot
        let projection = OverviewViewportProjection(
            wmController: wmController,
            snapshot: overviewSnapshot,
            scale: presentation.configuredScale
        )
        self.projection = projection
        focusSession = OverviewFocusSession(
            wmController: wmController,
            environment: environment,
            projection: projection,
            snapshot: overviewSnapshot
        )
        let mutationSession = OverviewMutationSession(
            wmController: wmController,
            projection: projection,
            windowFacts: windowFacts,
            structuralActions: structuralActions
        )
        self.mutationSession = mutationSession
        let windowSession = OverviewWindowSession(projection: projection, ownedWindowRegistry: ownedWindowRegistry)
        self.windowSession = windowSession
        drag = OverviewDragSession(
            projection: projection,
            snapshot: overviewSnapshot,
            windowSession: windowSession,
            structuralActions: structuralActions,
            mutationSession: mutationSession
        )
        thumbnailCapture = OverviewThumbnailCapture(
            wmController: wmController, environment: environment, ownedWindowRegistry: ownedWindowRegistry,
            snapshot: overviewSnapshot, projection: projection, windowSession: windowSession
        )
        input = OverviewInputHandler(
            projection: projection,
            windowSession: windowSession,
            focusSession: focusSession,
            snapshot: overviewSnapshot
        )
        self.wmController = wmController
        self.motionPolicy = motionPolicy
        self.environment = environment
        inputSession = OverviewInputSession(environment: environment)
        connectSession(displayLinkFactory: displayLinkFactory, animationMediaTimeProvider: animationMediaTimeProvider)
    }

    private func connectSession(
        displayLinkFactory: @escaping OverviewAnimator.DisplayLinkFactory,
        animationMediaTimeProvider: @escaping OverviewAnimator.MediaTimeProvider
    ) {
        drag.connect(overview: self)
        focusSession.connect(overview: self)
        mutationSession.connect(overview: self)
        animator = OverviewAnimator(
            controller: self,
            displayLinkFactory: displayLinkFactory,
            mediaTimeProvider: animationMediaTimeProvider
        )
        input.connect(controller: self)
    }

    deinit {
        MainActor.assumeIsolated {
            endOwnedSession()
            cleanup()
        }
    }
}

extension OverviewController {
    func toggle() {
        switch state {
        case .closed:
            open()
        case .opening,
             .open:
            input.dismissToSelection(animated: true)
        case .closing:
            reverseClosingTransition()
        }
    }

    func performStructuralHotkey(_ command: HotkeyCommand, selectedHandle: WindowHandle) -> StructuralMutationOutcome? {
        structuralActions.performStructuralHotkey(command, selectedHandle: selectedHandle)
    }

    @discardableResult
    func executeStructuralHotkey(
        _ command: HotkeyCommand,
        selectedHandle: WindowHandle
    ) -> StructuralMutationOutcome? {
        guard !mutationSession.isTransferring else { return .unchanged }
        let outcome = performStructuralHotkey(command, selectedHandle: selectedHandle)
        if let outcome, case let .changed(mutation) = outcome {
            mutationSession.completeStructuralMutation(mutation)
        }
        return outcome
    }

    func open() {
        guard case .closed = state else { return }
        guard wmController != nil else { return }

        focusSession.invalidateSelectionDismissal()
        focusSession.advancePostCloseHandoffGeneration()
        focusSession.pendingPostCloseHandoffValidity = nil

        prepareOpenState()
        windowSession.createWindows(
            controller: self,
            monitors: wmController?.workspaceManager.monitors ?? [],
            palette: presentation.renderPalette
        )
        beginOwnedSession()
        thumbnailCapture.startThumbnailCapture()

        if motionPolicy.animationsEnabled {
            state = .opening
        } else {
            state = .open
            animator?.cancelAnimation()
        }

        updateWindowDisplays()
        windowSession.showWindows()
        activateOwnedSession()
        windowSession.primaryOverviewWindow()?.show(asKeyWindow: true)
        if motionPolicy.animationsEnabled {
            animator?.startOpenAnimation(displayIds: windowSession.displayIds)
        }
    }

    private func reverseClosingTransition() {
        guard case .closing = state else { return }

        focusSession.invalidateSelectionDismissal()
        focusSession.advancePostCloseHandoffGeneration()
        focusSession.pendingDismissReason = .cancel
        focusSession.pendingFocusTargetWindow = nil
        focusSession.pendingPostCloseHandoffValidity = nil
        state = motionPolicy.animationsEnabled ? .opening : .open
        updateWindowDisplays()
        activateOwnedSession()
        windowSession.primaryOverviewWindow()?.show(asKeyWindow: true)

        if motionPolicy.animationsEnabled {
            animator?.startOpenAnimation(displayIds: windowSession.displayIds)
        } else {
            animator?.cancelAnimation()
        }
    }

    func prepareOpenState() {
        guard let wmController else { return }

        projection.activeInteractionMonitorId = wmController.monitorForInteraction()?.id
        presentation = OverviewPresentation(settings: wmController.settings)
        projection.scale = presentation.configuredScale
        overviewSnapshot.build()

        if let focusedHandle = wmController.workspaceManager.selectedManagedHandle,
           overviewSnapshot.windows[focusedHandle] != nil
        {
            projection.selectedWindowHandle = focusedHandle
        }

        projection.rebuildProjectedLayouts()
    }

    func updateSettings() {
        guard let wmController else { return }

        let (scaleChanged, appearanceChanged) = presentation.update(settings: wmController.settings)

        guard state.isOpen else {
            projection.scale = presentation.configuredScale
            return
        }
        guard scaleChanged || appearanceChanged else { return }

        if scaleChanged {
            let anchors = projection.captureSelectedViewportAnchors()
            projection.scale = presentation.configuredScale
            projection.rebuildProjectedLayouts(preservingSelectedAnchors: anchors)
            updateWindowDisplays(palette: appearanceChanged ? presentation.renderPalette : nil)
        } else {
            windowSession.updatePalette(presentation.renderPalette)
        }
    }

    func dismiss(
        reason: OverviewDismissReason = .cancel,
        targetWindow: WindowHandle? = nil,
        animated: Bool
    ) {
        switch state {
        case .closed:
            return
        case .closing:
            if reason == .externalDeactivation {
                focusSession.pendingDismissReason = .externalDeactivation
                focusSession.pendingFocusTargetWindow = nil
                focusSession.pendingPostCloseHandoffValidity = nil
            }
            return
        case .opening,
             .open:
            break
        }

        focusSession.invalidateSelectionDismissal()
        if hasActiveDragSession {
            drag.cancelDrag()
        }

        let resolvedTargetWindow = reason == .selection ? targetWindow : nil
        focusSession.pendingDismissReason = reason
        focusSession.pendingFocusTargetWindow = resolvedTargetWindow
        if let resolvedTargetWindow {
            wmController?.windowActionHandler.prepareWindowFromOverview(resolvedTargetWindow, animated: animated)
        }
        focusSession.pendingPostCloseHandoffValidity = focusSession.currentPostCloseHandoffValidity()

        state = .closing(targetWindow: resolvedTargetWindow)

        if animated && motionPolicy.animationsEnabled {
            animator?.startCloseAnimation(
                targetWindow: resolvedTargetWindow,
                displayIds: windowSession.displayIds
            )
        } else {
            completeCloseTransition(targetWindow: resolvedTargetWindow)
        }
    }

    func refreshCachedOverviewProjection(
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        selectedHandle: WindowHandle? = nil
    ) {
        guard state.isOpen, let wmController else { return }
        environment.onCachedProjectionRefreshed(affectedWorkspaceIds)
        let anchors = projection.captureSelectedViewportAnchors()
        let workspaceManager = wmController.workspaceManager
        let previousWindowIds = Set(overviewSnapshot.windowIds)

        overviewSnapshot.refresh(affectedWorkspaceIds: affectedWorkspaceIds)

        if let selectedHandle,
           overviewSnapshot.windows[selectedHandle] != nil,
           workspaceManager.entry(for: selectedHandle) != nil
        {
            projection.selectedWindowHandle = selectedHandle
        }
        projection.rebuildProjectedLayouts(preservingSelectedAnchors: anchors)
        updateWindowDisplays()

        let addedWindowIds = Set(overviewSnapshot.windowIds).subtracting(previousWindowIds)
        let uncachedAddedWindowIds = addedWindowIds.filter { thumbnailCache[$0] == nil }
        if !uncachedAddedWindowIds.isEmpty {
            let uncachedWindowIds = Set(overviewSnapshot.windowIds.filter { thumbnailCache[$0] == nil })
            thumbnailCapture.startThumbnailCapture(windowIds: uncachedWindowIds)
        }
    }

    private func updateWindowDisplays(palette: OverviewRenderPalette? = nil, thumbnails: [Int: CGImage]? = nil) {
        windowSession.updateWindowDisplays(state: state, palette: palette, thumbnails: thumbnails)
    }

    func updateAnimationProgress(
        _ progress: Double,
        on displayId: CGDirectDisplayID,
        generation: UInt64,
        sequence: UInt64
    ) {
        windowSession.updateAnimationProgress(
            progress, on: displayId, state: state, generation: generation, sequence: sequence
        )
    }

    private func handleModifierFlagsChanged(_ modifierFlags: NSEvent.ModifierFlags) {
        guard state.isOpen else { return }
        windowSession.handleModifierFlagsChanged(modifierFlags)
    }

    #if DEBUG
        @discardableResult
        func startThumbnailCaptureForTests(
            windowId: Int,
            capture: @escaping @Sendable () async -> CGImage?
        ) -> Task<Void, Never> {
            thumbnailCapture.startThumbnailCaptureForTests(windowId: windowId, capture: capture)
        }
    #endif

    func onAnimationComplete(state: OverviewState) {
        self.state = state
        updateWindowDisplays()
    }

    func completeCloseTransition(targetWindow: WindowHandle?) {
        focusSession.completeCloseTransition(targetWindow: targetWindow) {
            animator?.cancelAnimation()
            state = .closed
            cleanup()
            endOwnedSession()
            updateWindowDisplays()
        }
    }

    func focusTargetWindow(_ handle: WindowHandle) {
        guard let wmController else { return }
        guard wmController.workspaceManager.handle(for: handle.id) === handle,
              let entry = wmController.workspaceManager.entry(for: handle)
        else {
            return
        }

        onActivateWindow?(handle, entry.workspaceId)
    }

    func invalidateDeferredActionsForServiceStop() {
        focusSession.invalidateSelectionDismissal()
        focusSession.advancePostCloseHandoffGeneration()
        focusSession.pendingDismissReason = .externalDeactivation
        focusSession.pendingFocusTargetWindow = nil
        focusSession.pendingPostCloseHandoffValidity = nil
        guard state.isOpen else { return }
        completeCloseTransition(targetWindow: nil)
    }

    @discardableResult
    func closeWindow(_ handle: WindowHandle) -> Bool {
        guard case .open = state else { return false }
        return onCloseWindow?(handle) == true
    }

    func handleManagedWindowRemoved(_ entry: WindowState) {
        guard state.isOpen else { return }
        thumbnailCapture.remove(windowId: entry.windowId)
        guard let removedHandle = overviewSnapshot.windows.first(where: { $0.value.token == entry.token })?.key else {
            return
        }
        let visibleOrder = projection.canonicalLayout()?.allWindows
            .filter(\.matchesSearch)
            .map(\.handle) ?? []
        guard overviewSnapshot.remove(removedHandle) != nil else { return }

        var nextSelection = projection.selectedWindowHandle
        if projection.selectedWindowHandle == removedHandle {
            nextSelection = OverviewNavigation.selectionAfterRemoving(
                removedHandle,
                from: visibleOrder,
                availableHandles: Set(overviewSnapshot.windows.keys)
            )
            projection.selectedWindowHandle = nextSelection
        }
        if focusSession.pendingFocusTargetWindow == removedHandle {
            focusSession.pendingFocusTargetWindow = nextSelection
        }

        refreshCachedOverviewProjection(
            affectedWorkspaceIds: [entry.workspaceId],
            selectedHandle: nextSelection
        )
    }

    func beginOwnedSession() {
        focusSession.capturePreviousFrontmostApplication()
        inputSession.start(
            inputHandler: input,
            onFlagsChanged: { [weak self] in self?.handleModifierFlagsChanged($0) },
            onResignActive: { [weak self] in self?.handleApplicationDidResignActive() },
            onDisplayChange: { [weak self] in self?.handleDisplayConfigurationChanged() }
        )
        focusSession.pendingDismissReason = .cancel
        focusSession.pendingFocusTargetWindow = nil
        focusSession.pendingPostCloseHandoffValidity = nil
    }

    func activateOwnedSession() {
        environment.activateOmniWM()
    }

    func handleApplicationDidResignActive() {
        guard state.isOpen else { return }
        dismiss(reason: .externalDeactivation, animated: true)
    }

    private func cleanup() {
        focusSession.invalidateSelectionDismissal()
        thumbnailCapture.clear()
        input.reset()
        projection.searchQuery = ""
        projection.scale = 1.0
        projection.selectedWindowHandle = nil
        projection.activeInteractionMonitorId = nil
        overviewSnapshot.reset()
        projection.resetLayouts()
        drag.reset()
        mutationSession.reset()
        windowSession.closeWindows()
    }

    private func handleDisplayConfigurationChanged() {
        guard state.isOpen else { return }
        completeCloseTransition(targetWindow: nil)
    }

    private func endOwnedSession() {
        inputSession.stop()
        focusSession.previousFrontmostApplicationPID = nil
        focusSession.pendingDismissReason = .cancel
        focusSession.pendingFocusTargetWindow = nil
        focusSession.pendingPostCloseHandoffValidity = nil
    }

    var hasActiveDragSession: Bool {
        drag.isActive
    }
}
