// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

@MainActor
final class NativeFullscreenSurfaceState {
    private var nativeFullscreenDescriptorsByOriginalToken: [WindowToken: NativeFullscreenPlaceholderUpdate] = [:]
    private var nativeFullscreenSlotsByWorkspace: [WorkspaceDescriptor.ID: AcceptedNativeFullscreenSlotProjection] = [:]

    var projectedWorkspaceIds: Set<WorkspaceDescriptor.ID> {
        Set(nativeFullscreenSlotsByWorkspace.keys)
    }

    func descriptor(for originalToken: WindowToken) -> NativeFullscreenPlaceholderUpdate? {
        nativeFullscreenDescriptorsByOriginalToken[originalToken]
    }

    func replaceDescriptors(_ descriptors: [NativeFullscreenPlaceholderUpdate]) {
        nativeFullscreenDescriptorsByOriginalToken.removeAll(keepingCapacity: true)
        for descriptor in descriptors {
            nativeFullscreenDescriptorsByOriginalToken[descriptor.originalToken] = descriptor
        }
    }

    func cleanup() {
        nativeFullscreenDescriptorsByOriginalToken.removeAll()
        nativeFullscreenSlotsByWorkspace.removeAll()
    }

    func accept(_ update: NativeFullscreenSurfaceProjectionUpdate, controller: WMController) -> Bool {
        let slots = update.slots
        let workspaceId = update.workspaceId
        let displayId = update.displayId
        let displayContext = update.displayContext
        guard controller.hasStartedServices else {
            NativeFullscreenSurfaceTrace.traceIncomingProjectionDiscarded(
                update,
                reason: .servicesStopped
            )
            nativeFullscreenSlotsByWorkspace.removeValue(forKey: workspaceId)
            return false
        }
        guard controller.workspaceManager.descriptor(for: workspaceId) != nil else {
            NativeFullscreenSurfaceTrace.traceIncomingProjectionDiscarded(
                update,
                reason: .workspaceMissing
            )
            nativeFullscreenSlotsByWorkspace.removeValue(forKey: workspaceId)
            return false
        }
        guard controller.workspaceManager.monitor(for: workspaceId)?.displayId == displayId else {
            NativeFullscreenSurfaceTrace.traceIncomingProjectionDiscarded(
                update,
                reason: .displayMismatch
            )
            return false
        }
        if slots.isEmpty, !controller.workspaceManager.hasNativeFullscreenLifecycleContext {
            nativeFullscreenSlotsByWorkspace.removeValue(forKey: workspaceId)
            return false
        }

        let traceIsActive = NativeFullscreenPlaceholderTrace.isActive
        let previousProjection = traceIsActive ? nativeFullscreenSlotsByWorkspace[workspaceId] : nil
        nativeFullscreenSlotsByWorkspace[workspaceId] = AcceptedNativeFullscreenSlotProjection(
            displayId: displayId,
            displayContext: displayContext,
            slots: slots
        )
        NativeFullscreenSurfaceTrace.traceProjectionAcceptedIfSignificant(
            update,
            previous: previousProjection,
            isActive: traceIsActive
        )

        return true
    }

    func prepareForReconcile(servicesStarted: Bool, workspaceManager: WorkspaceManager) {
        if !servicesStarted {
            nativeFullscreenSlotsByWorkspace.removeAll(keepingCapacity: true)
        } else {
            let staleWorkspaceIds = nativeFullscreenSlotsByWorkspace.keys.filter {
                workspaceManager.descriptor(for: $0) == nil
            }
            for workspaceId in staleWorkspaceIds {
                if let removed = nativeFullscreenSlotsByWorkspace.removeValue(forKey: workspaceId) {
                    NativeFullscreenSurfaceTrace.traceIncomingProjectionDiscarded(
                        NativeFullscreenSurfaceProjectionUpdate(
                            slots: removed.slots,
                            workspaceId: workspaceId,
                            displayId: removed.displayId,
                            displayContext: removed.displayContext
                        ),
                        reason: .workspaceMissing
                    )
                }
            }
        }
    }

    func diagnostics(
        applied: [NativeFullscreenPlaceholderUpdate],
        controller: WMController?
    ) -> FullscreenSurfaceDiagnosticsSnapshot {
        let acceptedSlots = acceptedSlotDiagnostics()
        let descriptors = nativeFullscreenDescriptorsByOriginalToken.values.sorted {
            ($0.originalToken.pid, $0.originalToken.windowId)
                < ($1.originalToken.pid, $1.originalToken.windowId)
        }
        var appliedCounts: [WindowToken: Int] = [:]
        for applied in applied {
            appliedCounts[applied.originalToken, default: 0] += 1
        }
        return FullscreenSurfaceDiagnosticsSnapshot(
            descriptors: descriptors,
            acceptedProjections: nativeFullscreenSlotsByWorkspace.map { workspaceId, projection in
                FullscreenAcceptedProjectionDiagnostics(
                    workspaceId: workspaceId,
                    displayId: projection.displayId,
                    workingFrame: projection.displayContext.workingFrame,
                    scale: projection.displayContext.scale,
                    slotCount: projection.slots.count
                )
            }
            .sorted { $0.workspaceId.uuidString < $1.workspaceId.uuidString },
            acceptedSlots: acceptedSlots.sorted {
                ($0.originalToken.pid, $0.originalToken.windowId, $0.workspaceId.uuidString)
                    < ($1.originalToken.pid, $1.originalToken.windowId, $1.workspaceId.uuidString)
            },
            applied: applied,
            resolutions: descriptors.map { descriptor in
                let previous = applied.first { $0.originalToken == descriptor.originalToken }
                return FullscreenSurfaceResolutionDiagnostics(
                    originalToken: descriptor.originalToken,
                    reason: controller.map {
                        resolvedNativeFullscreenPlaceholder(
                            descriptor,
                            previous: previous,
                            controller: $0
                        ).reason
                    } ?? .controllerUnavailable
                )
            },
            appliedDuplicateOriginalTokens: appliedCounts.compactMap { $0.value > 1 ? $0.key : nil }
        )
    }

    private func acceptedSlotDiagnostics() -> [NativeFullscreenAcceptedSlotDiagnostics] {
        var acceptedSlots: [NativeFullscreenAcceptedSlotDiagnostics] = []
        acceptedSlots.reserveCapacity(nativeFullscreenSlotsByWorkspace.values.reduce(0) { $0 + $1.slots.count })
        for (workspaceId, projection) in nativeFullscreenSlotsByWorkspace {
            for (originalToken, slot) in projection.slots {
                acceptedSlots.append(
                    NativeFullscreenAcceptedSlotDiagnostics(
                        originalToken: originalToken,
                        currentToken: slot.currentToken,
                        workspaceId: workspaceId,
                        displayId: projection.displayId,
                        frame: slot.frame,
                        visible: slot.visible,
                        workingFrame: projection.displayContext.workingFrame,
                        scale: projection.displayContext.scale
                    )
                )
            }
        }
        return acceptedSlots
    }

    func resolvedNativeFullscreenPlaceholder(
        _ descriptor: NativeFullscreenPlaceholderUpdate,
        previous: NativeFullscreenPlaceholderUpdate?,
        controller: WMController
    ) -> NativeFullscreenPlaceholderResolution {
        let workspaceManager = controller.workspaceManager
        guard let record = workspaceManager.nativeFullscreenRecord(originalToken: descriptor.originalToken) else {
            return NativeFullscreenPlaceholderResolution(
                update: NativeFullscreenPlaceholderResolver.hidden(
                    descriptor,
                    currentToken: descriptor.currentToken,
                    selected: descriptor.selected,
                    previous: previous
                ),
                reason: .recordMissing
            )
        }
        guard record.workspaceId == descriptor.workspaceId else {
            return NativeFullscreenPlaceholderResolution(
                update: NativeFullscreenPlaceholderResolver.hidden(
                    descriptor,
                    currentToken: record.currentToken,
                    selected: descriptor.selected,
                    previous: previous
                ),
                reason: .recordWorkspaceMismatch
            )
        }

        let currentToken = record.currentToken
        let resolver = NativeFullscreenPlaceholderResolver(
            descriptor: descriptor,
            previous: previous,
            currentToken: currentToken,
            selected: workspaceManager.selectedManagedToken == currentToken
                || workspaceManager.pendingFocusedToken == currentToken
        )
        if let resolution = resolver.resolveLifecycle(record: record, workspaceManager: workspaceManager) {
            return resolution
        }
        return resolver.resolveProjection(
            nativeFullscreenSlotsByWorkspace[descriptor.workspaceId],
            workspaceManager: workspaceManager
        )
    }
}
