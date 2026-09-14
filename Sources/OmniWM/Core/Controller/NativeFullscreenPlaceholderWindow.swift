// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreText

@MainActor
final class NativeFullscreenPlaceholderWindow: NSPanel {
    private static let captureExclusionRetryDelays: [Duration] = [
        .milliseconds(50),
        .milliseconds(150),
        .milliseconds(400)
    ]

    private let placeholderView: NativeFullscreenPlaceholderView
    private let originalToken: WindowToken
    private let surfaceId: String
    private var currentToken: WindowToken?
    private var workspaceId: WorkspaceDescriptor.ID?
    private var slotFrame: CGRect
    private var displayContext: NativeFullscreenDisplayContext?
    private var appliedPanelFrame: CGRect?
    private var descriptorVisible: Bool
    private var appliedVisible = false
    private var registeredWindowNumber: Int?
    private var excludedWindowNumber: Int?
    private var captureExclusionOutcome: NativeFullscreenCaptureExclusionOutcome?
    private var captureExclusionRetryIndex = 0
    private var captureExclusionRetryExhausted = false
    private var captureExclusionRetryTask: Task<Void, Never>?

    var onActivate: ((WindowToken) -> Void)?

    init(placeholder: NativeFullscreenPlaceholderUpdate, appName: String?, icon: NSImage?) {
        originalToken = placeholder.originalToken
        surfaceId = "native-fullscreen-placeholder-\(placeholder.originalToken.pid)-\(placeholder.originalToken.windowId)"
        currentToken = placeholder.currentToken
        workspaceId = placeholder.workspaceId
        slotFrame = placeholder.frame
        displayContext = placeholder.displayContext
        descriptorVisible = placeholder.visible
        placeholderView = NativeFullscreenPlaceholderView(appName: appName, icon: icon)
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = false
        isOpaque = false
        backgroundColor = .clear
        level = .normal
        ignoresMouseEvents = false
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        placeholderView.onActivate = { [weak self] in
            self?.activate()
        }
        placeholderView.setSelected(placeholder.selected)
        contentView = placeholderView
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    func prepareSurface() {
        registerSurface()
        ensureCaptureExclusion(schedulesRetry: false)
    }

    func update(
        _ update: NativeFullscreenPlaceholderUpdate,
        forceOrdering: Bool
    ) {
        currentToken = update.currentToken
        workspaceId = update.workspaceId
        slotFrame = update.frame
        displayContext = update.displayContext
        descriptorVisible = update.visible
        placeholderView.setSelected(update.selected)
        reconcileGeometry(forceOrdering: forceOrdering)
    }

    func moveForAnimation(
        slotFrame: CGRect,
        displayContext: NativeFullscreenDisplayContext?
    ) {
        self.slotFrame = slotFrame
        self.displayContext = displayContext
        guard descriptorVisible else { return }
        reconcileGeometry(forceOrdering: false)
    }

    func destroy() {
        cancelCaptureExclusionRetry(resetsAttempts: true)
        NativeFullscreenPlaceholderTrace.record(
            NativeFullscreenPlaceholderTrace.makeRecord(
                .panelDestroyed,
                originalToken: originalToken,
                currentToken: currentToken,
                workspaceId: workspaceId,
                slotFrame: slotFrame,
                panelFrame: appliedPanelFrame,
                visible: isVisible,
                windowNumber: windowNumber
            )
        )
        SurfaceCoordinator.shared.unregister(id: surfaceId)
        orderOut(nil)
        close()
    }

    func diagnosticsSnapshot() -> NativeFullscreenPanelDiagnostics {
        let panelWindowNumber = windowNumber
        let registryCaptureEligible = panelWindowNumber > 0
            ? SurfaceCoordinator.shared.isCaptureEligible(windowNumber: panelWindowNumber)
            : nil
        let skyLightCaptureExcluded = UInt32(exactly: panelWindowNumber).flatMap {
            SkyLight.shared.isExcludedFromScreencaptureWindowSelection($0)
        }
        return NativeFullscreenPanelDiagnostics(
            originalToken: originalToken,
            currentToken: currentToken,
            workspaceId: workspaceId,
            slotFrame: slotFrame,
            displayContext: displayContext,
            panelFrame: appliedPanelFrame,
            windowFrame: frame,
            descriptorVisible: descriptorVisible,
            appliedVisible: appliedVisible,
            windowVisible: isVisible,
            windowNumber: panelWindowNumber,
            level: level.rawValue,
            orderedIndex: orderedIndex,
            onActiveSpace: isOnActiveSpace,
            collectionBehavior: collectionBehavior.rawValue,
            registeredWindowNumber: registeredWindowNumber,
            registryCaptureEligible: registryCaptureEligible,
            skyLightCaptureExcluded: skyLightCaptureExcluded,
            excludedWindowNumber: excludedWindowNumber,
            captureExclusionOutcome: captureExclusionOutcome,
            captureRetryIndex: captureExclusionRetryIndex,
            captureRetryPending: captureExclusionRetryTask != nil,
            captureRetryExhausted: captureExclusionRetryExhausted
        )
    }

    private func reconcileGeometry(forceOrdering: Bool) {
        guard descriptorVisible,
              let displayContext,
              let panelFrame = NativeFullscreenPlaceholderGeometry.resolve(
                  slotFrame: slotFrame,
                  workingFrame: displayContext.workingFrame
              )
        else {
            hidePanel()
            return
        }

        applyPanelFrame(panelFrame)

        if !isVisible || forceOrdering {
            let wasVisible = isVisible
            orderBack(nil)
            appliedVisible = true
            NativeFullscreenPlaceholderTrace.record(
                NativeFullscreenPlaceholderTrace.makeRecord(
                    wasVisible ? .panelOrdered : .panelShown,
                    originalToken: originalToken,
                    currentToken: currentToken,
                    workspaceId: workspaceId,
                    slotFrame: slotFrame,
                    panelFrame: appliedPanelFrame,
                    visible: isVisible,
                    windowNumber: windowNumber,
                    reason: isVisible ? .accepted : .orderingFailed
                )
            )
            ensureCaptureExclusion(schedulesRetry: true)
        } else {
            appliedVisible = true
        }
    }

    private func applyPanelFrame(_ nextFrame: CGRect) {
        guard appliedPanelFrame != nextFrame || frame != nextFrame else { return }
        let sizeChanged = frame.size != nextFrame.size
        if frame.size == nextFrame.size {
            setFrameOrigin(nextFrame.origin)
        } else {
            setFrame(nextFrame, display: false)
        }
        appliedPanelFrame = nextFrame
        NativeFullscreenPlaceholderTrace.record(
            NativeFullscreenPlaceholderTrace.makeRecord(
                sizeChanged ? .panelResized : .panelMoved,
                originalToken: originalToken,
                currentToken: currentToken,
                workspaceId: workspaceId,
                slotFrame: slotFrame,
                panelFrame: nextFrame,
                visible: isVisible,
                windowNumber: windowNumber
            )
        )
        if sizeChanged {
            placeholderView.needsDisplay = true
        }
    }

    private func hidePanel() {
        cancelCaptureExclusionRetry(resetsAttempts: true)
        placeholderView.cancelInteraction()
        if appliedVisible || isVisible {
            orderOut(nil)
            NativeFullscreenPlaceholderTrace.record(
                NativeFullscreenPlaceholderTrace.makeRecord(
                    .panelHidden,
                    originalToken: originalToken,
                    currentToken: currentToken,
                    workspaceId: workspaceId,
                    slotFrame: slotFrame,
                    panelFrame: appliedPanelFrame,
                    visible: false,
                    windowNumber: windowNumber,
                    reason: descriptorVisible ? .geometryRejected : .descriptorHidden
                )
            )
        }
        appliedVisible = false
    }

    private func activate() {
        NativeFullscreenPlaceholderTrace.record(
            NativeFullscreenPlaceholderTrace.makeRecord(
                .activationRequested,
                originalToken: originalToken,
                currentToken: currentToken,
                workspaceId: workspaceId,
                slotFrame: slotFrame,
                panelFrame: appliedPanelFrame,
                visible: isVisible,
                windowNumber: windowNumber
            )
        )
        onActivate?(originalToken)
    }

    private func registerSurface() {
        SurfaceCoordinator.shared.register(
            window: self,
            id: surfaceId,
            policy: SurfacePolicy(
                kind: .nativeFullscreenPlaceholder,
                hitTestPolicy: .interactive,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
        registeredWindowNumber = windowNumber > 0 ? windowNumber : nil
    }
}

extension NativeFullscreenPlaceholderWindow {
    private func ensureCaptureExclusion(schedulesRetry: Bool) {
        let panelWindowNumber = windowNumber
        guard panelWindowNumber > 0 else {
            if schedulesRetry {
                scheduleCaptureExclusionRetry()
            }
            return
        }
        if registeredWindowNumber != panelWindowNumber {
            registerSurface()
        }
        guard excludedWindowNumber != panelWindowNumber else {
            cancelCaptureExclusionRetry(resetsAttempts: false)
            return
        }
        let windowId = UInt32(panelWindowNumber)
        recordCapture(.captureAttempt, windowNumber: panelWindowNumber, reason: nil)
        let writeAccepted = SkyLight.shared.excludeFromScreencaptureWindowSelection(windowId)
        let readback = writeAccepted
            ? SkyLight.shared.isExcludedFromScreencaptureWindowSelection(windowId)
            : nil
        captureExclusionOutcome = NativeFullscreenCaptureExclusionOutcome.resolve(
            writeAccepted: writeAccepted,
            readback: readback
        )
        if captureExclusionOutcome == .verified || captureExclusionOutcome == .acceptedUnverified {
            excludedWindowNumber = panelWindowNumber
            let reason: NativeFullscreenPlaceholderTrace.Reason = captureExclusionOutcome == .verified
                ? .captureVerified
                : .captureUnverified
            recordCapture(.captureExcluded, windowNumber: panelWindowNumber, reason: reason)
            cancelCaptureExclusionRetry(resetsAttempts: false)
        } else if schedulesRetry {
            scheduleCaptureExclusionRetry()
        }
    }

    private func scheduleCaptureExclusionRetry() {
        guard captureExclusionRetryTask == nil else { return }
        guard Self.captureExclusionRetryDelays.indices.contains(captureExclusionRetryIndex) else {
            if !captureExclusionRetryExhausted {
                FallbackFiringRecorder.shared.note(.capture, "nativeFullscreenPlaceholderExclusionRetryExhausted")
                captureExclusionRetryExhausted = true
                recordCapture(.captureRetryExhausted, windowNumber: windowNumber, reason: .captureFailed)
            }
            return
        }

        let delay = Self.captureExclusionRetryDelays[captureExclusionRetryIndex]
        captureExclusionRetryIndex += 1
        recordCapture(.captureRetryScheduled, windowNumber: windowNumber, reason: nil)
        captureExclusionRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self else { return }
            captureExclusionRetryTask = nil
            guard appliedVisible else { return }
            ensureCaptureExclusion(schedulesRetry: true)
        }
    }

    private func cancelCaptureExclusionRetry(resetsAttempts: Bool) {
        if let captureExclusionRetryTask {
            captureExclusionRetryTask.cancel()
            recordCapture(.captureRetryCancelled, windowNumber: windowNumber, reason: nil)
        }
        captureExclusionRetryTask = nil
        if resetsAttempts {
            captureExclusionRetryIndex = 0
            captureExclusionRetryExhausted = false
        }
    }

    private func recordCapture(
        _ operation: NativeFullscreenPlaceholderTrace.Operation,
        windowNumber: Int,
        reason: NativeFullscreenPlaceholderTrace.Reason?
    ) {
        NativeFullscreenPlaceholderTrace.record(
            NativeFullscreenPlaceholderTrace.makeRecord(
                operation,
                originalToken: originalToken,
                currentToken: currentToken,
                workspaceId: workspaceId,
                visible: appliedVisible,
                windowNumber: windowNumber,
                reason: reason,
                retryIndex: captureExclusionRetryIndex
            )
        )
    }
}
