// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreGraphics
import Foundation

struct FullscreenLifecycleDiagnosticsSnapshot {
    struct Record {
        let originalToken: WindowToken
        let currentToken: WindowToken
        let workspaceId: WorkspaceDescriptor.ID
        let transition: String
        let generation: Int
        let deadlineArmed: Bool
        let entryPresent: Bool
        let layoutReason: String?
        let workspaceVisible: Bool
        let appHidden: Bool
        let cornerHidden: Bool
        let displayId: CGDirectDisplayID?
        let displayUUID: String?
        let displayShowingFullscreen: Bool?

        func hiddenReason() -> String? {
            if !workspaceVisible { return "workspace-inactive" }
            if appHidden { return "app-hidden" }
            if cornerHidden { return "corner-hidden" }
            if displayShowingFullscreen == true { return "display-fullscreen-space" }
            if displayShowingFullscreen == nil { return "display-context-unresolved" }
            return nil
        }
    }

    let records: [Record]
    let nativeFocusOwner: NativeFocusOwner
    let activeFocusOwnerToken: WindowToken?
    let renderableFocusToken: WindowToken?
}

struct NativeFullscreenAcceptedSlotDiagnostics {
    let originalToken: WindowToken
    let currentToken: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    let displayId: CGDirectDisplayID
    let frame: CGRect
    let visible: Bool
    let workingFrame: CGRect
    let scale: CGFloat
}

struct FullscreenAcceptedProjectionDiagnostics {
    let workspaceId: WorkspaceDescriptor.ID
    let displayId: CGDirectDisplayID
    let workingFrame: CGRect
    let scale: CGFloat
    let slotCount: Int
}

struct FullscreenSurfaceDiagnosticsSnapshot {
    let descriptors: [NativeFullscreenPlaceholderUpdate]
    let acceptedProjections: [FullscreenAcceptedProjectionDiagnostics]
    let acceptedSlots: [NativeFullscreenAcceptedSlotDiagnostics]
    let applied: [NativeFullscreenPlaceholderUpdate]
    let resolutions: [FullscreenSurfaceResolutionDiagnostics]
    let appliedDuplicateOriginalTokens: [WindowToken]
}

struct FullscreenSurfaceResolutionDiagnostics {
    let originalToken: WindowToken
    let reason: NativeFullscreenPlaceholderTrace.Reason
}

struct NativeFullscreenPanelDiagnostics {
    let originalToken: WindowToken
    let currentToken: WindowToken?
    let workspaceId: WorkspaceDescriptor.ID?
    let slotFrame: CGRect
    let displayContext: NativeFullscreenDisplayContext?
    let panelFrame: CGRect?
    let windowFrame: CGRect
    let descriptorVisible: Bool
    let appliedVisible: Bool
    let windowVisible: Bool
    let windowNumber: Int
    let level: Int
    let orderedIndex: Int
    let onActiveSpace: Bool
    let collectionBehavior: UInt
    let registeredWindowNumber: Int?
    let registryCaptureEligible: Bool?
    let skyLightCaptureExcluded: Bool?
    let excludedWindowNumber: Int?
    let captureExclusionOutcome: NativeFullscreenCaptureExclusionOutcome?
    let captureRetryIndex: Int
    let captureRetryPending: Bool
    let captureRetryExhausted: Bool

    var frameSynchronized: Bool {
        guard let panelFrame else { return false }
        let scale = displayContext?.scale ?? 1
        let tolerance = 1 / max(scale.isFinite && scale > 0 ? scale : 1, 1) + 0.001
        return abs(panelFrame.minX - windowFrame.minX) <= tolerance
            && abs(panelFrame.minY - windowFrame.minY) <= tolerance
            && abs(panelFrame.width - windowFrame.width) <= tolerance
            && abs(panelFrame.height - windowFrame.height) <= tolerance
    }

    var captureSummary: String {
        "registeredWindow=\(optionalInt(registeredWindowNumber))"
            + " registryCaptureEligible=\(optionalBool(registryCaptureEligible))"
            + " skyLightExcluded=\(optionalBool(skyLightCaptureExcluded))"
            + " excludedWindow=\(optionalInt(excludedWindowNumber))"
            + " exclusionOutcome=\(captureExclusionOutcome?.rawValue ?? "none")"
            + " retryIndex=\(captureRetryIndex)"
            + " retryPending=\(captureRetryPending)"
            + " retryExhausted=\(captureRetryExhausted)"
    }

    func presentationReason(expectedToken: WindowToken) -> String {
        guard currentToken == expectedToken else { return "panel-token-mismatch" }
        guard descriptorVisible else { return "panel-descriptor-hidden" }
        guard panelFrame != nil else { return "geometry-rejected" }
        guard frameSynchronized else { return "panel-frame-desync" }
        guard onActiveSpace else { return "panel-off-active-space" }
        if appliedVisible, !windowVisible { return "ordering-failed" }
        guard appliedVisible, windowVisible else { return "panel-hidden" }
        return "visible"
    }

    private func optionalBool(_ value: Bool?) -> String {
        value.map(String.init) ?? "unknown"
    }

    private func optionalInt(_ value: Int?) -> String {
        value.map(String.init) ?? "none"
    }
}

@MainActor
struct FullscreenPlaceholderDiagnosticsSnapshot {
    let servicesStarted: Bool
    let lifecycle: FullscreenLifecycleDiagnosticsSnapshot
    let surface: FullscreenSurfaceDiagnosticsSnapshot
    let panels: [NativeFullscreenPanelDiagnostics]

    static func capture(_ controller: WMController) -> FullscreenPlaceholderDiagnosticsSnapshot {
        FullscreenPlaceholderDiagnosticsSnapshot(
            servicesStarted: controller.hasStartedServices,
            lifecycle: controller.workspaceManager.nativeFullscreenLifecycleDiagnosticsSnapshot(),
            surface: controller.surfaceReconciler.nativeFullscreenDiagnosticsSnapshot(),
            panels: controller.nativeFullscreenPlaceholderManager.diagnosticsSnapshot()
        )
    }

    func formatted() -> String {
        let index = Index(lifecycle: lifecycle, surface: surface, panels: panels)

        var lines = [
            "servicesStarted=\(servicesStarted) records=\(index.records.count) descriptors=\(index.descriptors.count)"
                + " acceptedProjections=\(surface.acceptedProjections.count)"
                + " acceptedSlots=\(surface.acceptedSlots.count) applied=\(index.applied.count) panels=\(index.panelMap.count)"
                +
                " appliedDuplicateStableIds=\(surface.appliedDuplicateOriginalTokens.map(token).joined(separator: ","))",
            "nativeFocusOwner=\(nativeFocusOwner(lifecycle.nativeFocusOwner))"
                + " focusOwner=\(token(lifecycle.activeFocusOwnerToken))"
                + " renderableFocus=\(token(lifecycle.renderableFocusToken))"
        ]
        lines.append(contentsOf: surface.acceptedProjections.map(format(projection:)))
        guard !index.tokens.isEmpty else {
            lines.append("placeholders: none")
            return lines.joined(separator: "\n")
        }

        for originalToken in index.tokens {
            let record = index.records[originalToken]
            let descriptor = index.descriptors[originalToken]
            let tokenSlots = index.slots[originalToken] ?? []
            let appliedEntry = index.applied[originalToken]
            let panel = index.panelMap[originalToken]
            let surfaceReason = surface.resolutions.first { $0.originalToken == originalToken }?.reason
            lines.append(
                "original=\(token(originalToken)) resolution="
                    + resolutionReason(
                        record: record,
                        descriptor: descriptor,
                        applied: appliedEntry,
                        panel: panel,
                        surfaceReason: surfaceReason
                    )
            )
            lines.append(format(record: record))
            lines.append(format(descriptor: descriptor))
            if tokenSlots.isEmpty {
                lines.append("  acceptedSlot=none")
            } else {
                lines.append(contentsOf: tokenSlots.sorted(by: slotOrder).map(format(slot:)))
            }
            lines.append(format(applied: appliedEntry))
            lines.append(format(panel: panel))
        }
        return lines.joined(separator: "\n")
    }

    private func resolutionReason(
        record: FullscreenLifecycleDiagnosticsSnapshot.Record?,
        descriptor: NativeFullscreenPlaceholderUpdate?,
        applied: NativeFullscreenPlaceholderUpdate?,
        panel: NativeFullscreenPanelDiagnostics?,
        surfaceReason: NativeFullscreenPlaceholderTrace.Reason?
    ) -> String {
        guard servicesStarted else { return "services-stopped" }
        guard let record else { return "orphan-no-record" }
        guard descriptor != nil else { return "descriptor-missing" }
        guard let surfaceReason else { return "surface-resolution-missing" }
        if surfaceReason == .layoutNotNativeFullscreen, !record.entryPresent {
            return "entry-missing"
        }
        if surfaceReason == .descriptorHidden, let reason = record.hiddenReason() {
            return reason
        }
        guard surfaceReason == .accepted else { return surfaceReason.rawValue }
        return appliedPresentationReason(applied: applied, panel: panel, currentToken: record.currentToken)
    }

    private func appliedPresentationReason(
        applied: NativeFullscreenPlaceholderUpdate?,
        panel: NativeFullscreenPanelDiagnostics?,
        currentToken: WindowToken
    ) -> String {
        guard let applied else { return "applied-missing" }
        guard applied.currentToken == currentToken else { return "applied-token-mismatch" }
        guard applied.visible else { return "applied-hidden" }
        guard let panel else { return "panel-missing" }
        return panel.presentationReason(expectedToken: currentToken)
    }

    private func format(record: FullscreenLifecycleDiagnosticsSnapshot.Record?) -> String {
        guard let record else { return "  record=none" }
        return "  record current=\(token(record.currentToken)) workspace=\(record.workspaceId.uuidString)"
            + " transition=\(record.transition) generation=\(record.generation)"
            + " deadline=\(record.deadlineArmed ? "armed" : "none")"
            + " entry=\(record.entryPresent) layout=\(record.layoutReason ?? "none")"
            + " workspaceVisible=\(record.workspaceVisible) appHidden=\(record.appHidden)"
            + " cornerHidden=\(record.cornerHidden) display=\(optionalDisplay(record.displayId))"
            + " displayUUID=\(record.displayUUID ?? "none")"
            + " displayFullscreen=\(optionalBool(record.displayShowingFullscreen))"
    }

    private func format(descriptor: NativeFullscreenPlaceholderUpdate?) -> String {
        guard let descriptor else { return "  descriptor=none" }
        return "  descriptor current=\(token(descriptor.currentToken))"
            + " workspace=\(descriptor.workspaceId.uuidString) frame=\(TraceFormat.rect(descriptor.frame))"
            + " selected=\(descriptor.selected) visible=\(descriptor.visible)"
            + " context=\(context(descriptor.displayContext))"
    }

    private func format(slot: NativeFullscreenAcceptedSlotDiagnostics) -> String {
        "  acceptedSlot current=\(token(slot.currentToken)) workspace=\(slot.workspaceId.uuidString)"
            + " display=\(slot.displayId) frame=\(TraceFormat.rect(slot.frame)) visible=\(slot.visible)"
            + " working=\(TraceFormat.rect(slot.workingFrame)) scale=\(scale(slot.scale))"
    }

    private func format(projection: FullscreenAcceptedProjectionDiagnostics) -> String {
        "acceptedProjection workspace=\(projection.workspaceId.uuidString) display=\(projection.displayId)"
            + " working=\(TraceFormat.rect(projection.workingFrame)) scale=\(scale(projection.scale))"
            + " slots=\(projection.slotCount)"
    }

    private func format(applied: NativeFullscreenPlaceholderUpdate?) -> String {
        guard let applied else { return "  applied=none" }
        return "  applied current=\(token(applied.currentToken)) workspace=\(applied.workspaceId.uuidString)"
            + " frame=\(TraceFormat.rect(applied.frame)) selected=\(applied.selected) visible=\(applied.visible)"
            + " context=\(context(applied.displayContext))"
    }

    private func format(panel: NativeFullscreenPanelDiagnostics?) -> String {
        guard let panel else { return "  panel=none" }
        return "  panel current=\(token(panel.currentToken)) workspace=\(workspace(panel.workspaceId))"
            + " slot=\(TraceFormat.rect(panel.slotFrame)) panelFrame=\(TraceFormat.rect(panel.panelFrame))"
            + " actual=\(TraceFormat.rect(panel.windowFrame))"
            + " frameSynchronized=\(panel.frameSynchronized)"
            + " descriptorVisible=\(panel.descriptorVisible)"
            + " appliedVisible=\(panel.appliedVisible) windowVisible=\(panel.windowVisible)"
            + " window=\(panel.windowNumber) level=\(panel.level) order=\(panel.orderedIndex)"
            + " activeSpace=\(panel.onActiveSpace) context=\(context(panel.displayContext))"
            + " collection=\(collectionBehavior(panel.collectionBehavior))"
            + " \(panel.captureSummary)"
    }

    private func context(_ value: NativeFullscreenDisplayContext?) -> String {
        guard let value else { return "none" }
        return "working:\(TraceFormat.rect(value.workingFrame)),scale:\(scale(value.scale))"
    }

    private func token(_ value: WindowToken?) -> String {
        value.map(token) ?? "none"
    }

    private func token(_ value: WindowToken) -> String {
        "\(value.pid):\(value.windowId)"
    }

    private func nativeFocusOwner(_ value: NativeFocusOwner) -> String {
        switch value {
        case let .managed(value):
            return "managed:\(token(value))"
        case let .external(identity):
            return "external:\(identity.pid.map(String.init) ?? "none"):\(identity.windowId.map(String.init) ?? "none")"
        case .ownedSurface:
            return "owned-surface"
        case .none:
            return "none"
        }
    }

    private func workspace(_ value: WorkspaceDescriptor.ID?) -> String {
        value?.uuidString ?? "none"
    }

    private func optionalDisplay(_ value: CGDirectDisplayID?) -> String {
        value.map(String.init) ?? "none"
    }

    private func optionalBool(_ value: Bool?) -> String {
        value.map(String.init) ?? "unknown"
    }

    private func scale(_ value: CGFloat) -> String {
        String(format: "%.2f", value)
    }

    private func collectionBehavior(_ rawValue: UInt) -> String {
        let behavior = NSWindow.CollectionBehavior(rawValue: rawValue)
        var values: [String] = []
        if behavior.contains(.canJoinAllSpaces) { values.append("canJoinAllSpaces") }
        if behavior.contains(.stationary) { values.append("stationary") }
        if behavior.contains(.ignoresCycle) { values.append("ignoresCycle") }
        if behavior.contains(.fullScreenAuxiliary) { values.append("fullScreenAuxiliary") }
        if behavior.contains(.fullScreenNone) { values.append("fullScreenNone") }
        if behavior.contains(.managed) { values.append("managed") }
        return "[\(values.joined(separator: ","))]:\(rawValue)"
    }

    private struct Index {
        let records: [WindowToken: FullscreenLifecycleDiagnosticsSnapshot.Record]
        let descriptors: [WindowToken: NativeFullscreenPlaceholderUpdate]
        let applied: [WindowToken: NativeFullscreenPlaceholderUpdate]
        let panelMap: [WindowToken: NativeFullscreenPanelDiagnostics]
        let slots: [WindowToken: [NativeFullscreenAcceptedSlotDiagnostics]]
        let tokens: [WindowToken]

        init(
            lifecycle: FullscreenLifecycleDiagnosticsSnapshot,
            surface: FullscreenSurfaceDiagnosticsSnapshot,
            panels: [NativeFullscreenPanelDiagnostics]
        ) {
            records = Self.dictionary(
                lifecycle.records,
                key: \FullscreenLifecycleDiagnosticsSnapshot.Record.originalToken
            )
            descriptors = Self.dictionary(surface.descriptors, key: \NativeFullscreenPlaceholderUpdate.originalToken)
            applied = Self.dictionary(surface.applied, key: \NativeFullscreenPlaceholderUpdate.originalToken)
            panelMap = Self.dictionary(panels, key: \NativeFullscreenPanelDiagnostics.originalToken)
            slots = Dictionary(
                grouping: surface.acceptedSlots,
                by: \NativeFullscreenAcceptedSlotDiagnostics.originalToken
            )
            tokens = Set(records.keys)
                .union(descriptors.keys)
                .union(slots.keys)
                .union(applied.keys)
                .union(panelMap.keys)
                .sorted(by: Self.tokenOrder)
        }

        private static func dictionary<Element, Key: Hashable>(
            _ elements: [Element],
            key: KeyPath<Element, Key>
        ) -> [Key: Element] {
            var result: [Key: Element] = [:]
            result.reserveCapacity(elements.count)
            for element in elements {
                result[element[keyPath: key]] = element
            }
            return result
        }

        private static func tokenOrder(_ lhs: WindowToken, _ rhs: WindowToken) -> Bool {
            (lhs.pid, lhs.windowId) < (rhs.pid, rhs.windowId)
        }
    }

    private func slotOrder(
        _ lhs: NativeFullscreenAcceptedSlotDiagnostics,
        _ rhs: NativeFullscreenAcceptedSlotDiagnostics
    ) -> Bool {
        if lhs.workspaceId != rhs.workspaceId {
            return lhs.workspaceId.uuidString < rhs.workspaceId.uuidString
        }
        return lhs.displayId < rhs.displayId
    }
}
