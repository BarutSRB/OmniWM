// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Carbon
import Foundation
import QuartzCore
import ScreenCaptureKit

@MainActor
final class OverviewViewportProjection {
    private weak var wmController: WMController?
    private let overviewSnapshot: OverviewSnapshot
    private(set) var layoutsByMonitor: [Monitor.ID: OverviewLayout] = [:]
    var searchQuery = ""
    var scale: CGFloat = 1.0
    var selectedWindowHandle: WindowHandle?
    var activeInteractionMonitorId: Monitor.ID?
    static let zoomEpsilon: CGFloat = 0.0001

    init(wmController: WMController, snapshot: OverviewSnapshot, scale: CGFloat) {
        self.wmController = wmController
        overviewSnapshot = snapshot
        self.scale = scale
    }

    func updateClosingWindowFrames(
        for targetWindow: WindowHandle,
        on displayId: CGDirectDisplayID
    ) -> OverviewLayout? {
        guard let wmController,
              let entry = wmController.workspaceManager.entry(for: targetWindow),
              wmController.activeWorkspace()?.id == entry.workspaceId,
              wmController.workspaceManager.activeLayoutKind(for: entry.workspaceId) == .niri,
              let monitor = wmController.workspaceManager.monitor(for: entry.workspaceId),
              monitor.displayId == displayId,
              let frames = wmController.niriEngine?.captureWindowFrames(in: entry.workspaceId),
              var layout = layoutsByMonitor[monitor.id]
        else { return nil }
        layout.updateOriginalFrames(frames, monitorFrame: monitor.frame)
        layoutsByMonitor[monitor.id] = layout
        return layout
    }

    func resetLayouts() {
        layoutsByMonitor = [:]
    }

    private enum ScrollTuning {
        static let preciseScrollMultiplier: CGFloat = 3.5
        static let nonPreciseScrollMultiplier: CGFloat = 2.0
        static let zoomStep: CGFloat = 0.05
    }

    struct SelectedViewportAnchor {
        let handle: WindowHandle
        let midpointY: CGFloat
    }

    func rebuildProjectedLayouts(
        preservingSelectedAnchors anchors: [Monitor.ID: SelectedViewportAnchor] = [:]
    ) {
        guard let wmController else { return }

        let previousLayouts = layoutsByMonitor
        let monitors = wmController.workspaceManager.monitors

        if let selectedWindowHandle,
           overviewSnapshot.windows[selectedWindowHandle] == nil
        {
            self.selectedWindowHandle = nil
        }

        layoutsByMonitor = [:]
        for monitor in monitors {
            var layout = projectedLayout(
                for: monitor,
                niriSnapshotsByWorkspace: overviewSnapshot.niriSnapshotsByWorkspace
            )
            let viewportFrame = OverviewLayoutCalculator.viewportFrame(for: monitor.frame)
            let previousOffset = previousLayouts[monitor.id]?.scrollOffset ?? 0
            layout.scrollOffset = OverviewLayoutCalculator.clampedScrollOffset(
                previousOffset,
                layout: layout,
                screenFrame: viewportFrame
            )
            layout.dragTarget = previousLayouts[monitor.id]?.dragTarget
            layoutsByMonitor[monitor.id] = layout
        }

        reconcileSelectedWindowHandle()

        if let activeInteractionMonitorId,
           layoutsByMonitor[activeInteractionMonitorId] == nil
        {
            self.activeInteractionMonitorId = nil
        }

        if activeInteractionMonitorId == nil {
            activeInteractionMonitorId = monitors.first?.id
        }

        restoreSelectedViewportAnchors(anchors)
        revealSelectedWindow(on: activeInteractionMonitorId)
    }

    private func projectedLayout(
        for monitor: Monitor,
        niriSnapshotsByWorkspace: [WorkspaceDescriptor.ID: NiriOverviewWorkspaceSnapshot]
    ) -> OverviewLayout {
        let localizedWindowData = overviewSnapshot.windows.mapValues { windowData in
            OverviewWindowLayoutData(
                token: windowData.token,
                workspaceId: windowData.workspaceId,
                title: windowData.title,
                appName: windowData.appName,
                appIcon: windowData.appIcon,
                frame: OverviewLayoutCalculator.localizedFrame(windowData.frame, to: monitor.frame)
            )
        }

        let viewportFrame = OverviewLayoutCalculator.viewportFrame(for: monitor.frame)
        var layout = OverviewLayoutCalculator(
            screenFrame: viewportFrame,
            scale: scale
        ).calculateLayout(
            workspaces: overviewSnapshot.workspaces,
            windows: localizedWindowData,
            niriSnapshotsByWorkspace: niriSnapshotsByWorkspace,
            searchQuery: searchQuery
        )
        layout.updateGroupCounts(overviewSnapshot.groupCountByHandle)
        return layout
    }

    func canonicalLayout(preferredMonitorId: Monitor.ID? = nil) -> OverviewLayout? {
        let monitorId = preferredMonitorId
            ?? activeInteractionMonitorId
            ?? wmController?.workspaceManager.monitors.first?.id
        if let monitorId,
           let layout = layoutsByMonitor[monitorId]
        {
            return layout
        }
        return layoutsByMonitor.values.first
    }

    func captureSelectedViewportAnchors() -> [Monitor.ID: SelectedViewportAnchor] {
        guard let selectedWindowHandle else { return [:] }

        var anchors: [Monitor.ID: SelectedViewportAnchor] = [:]
        anchors.reserveCapacity(layoutsByMonitor.count)
        for (monitorId, layout) in layoutsByMonitor {
            guard let window = layout.window(for: selectedWindowHandle), window.matchesSearch else { continue }
            anchors[monitorId] = SelectedViewportAnchor(
                handle: selectedWindowHandle,
                midpointY: window.overviewFrame.midY - layout.scrollOffset
            )
        }
        return anchors
    }

    private func restoreSelectedViewportAnchors(_ anchors: [Monitor.ID: SelectedViewportAnchor]) {
        guard let selectedWindowHandle else { return }

        for (monitorId, anchor) in anchors where anchor.handle == selectedWindowHandle {
            mutateLayout(for: monitorId) { layout in
                guard let window = layout.window(for: selectedWindowHandle), window.matchesSearch else { return }
                let screenFrame = viewportFrame(for: monitorId)
                layout.scrollOffset = OverviewLayoutCalculator.clampedScrollOffset(
                    window.overviewFrame.midY - anchor.midpointY,
                    layout: layout,
                    screenFrame: screenFrame
                )
            }
        }
    }

    @discardableResult
    func revealSelectedWindow(on monitorId: Monitor.ID?) -> Bool {
        guard let monitorId,
              let selectedWindowHandle,
              var layout = layoutsByMonitor[monitorId],
              let window = layout.window(for: selectedWindowHandle),
              window.matchesSearch
        else {
            return false
        }
        let scrollOffset = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: window.overviewFrame,
            currentOffset: layout.scrollOffset,
            layout: layout,
            screenFrame: viewportFrame(for: monitorId)
        )
        guard scrollOffset != layout.scrollOffset else { return false }
        layout.scrollOffset = scrollOffset
        layoutsByMonitor[monitorId] = layout
        return true
    }

    func setSelectedWindowHandle(_ handle: WindowHandle?) {
        selectedWindowHandle = handle
    }

    private func reconcileSelectedWindowHandle() {
        guard let layout = canonicalLayout(preferredMonitorId: activeInteractionMonitorId) else {
            selectedWindowHandle = nil
            return
        }

        if let selectedWindowHandle,
           let selectedWindow = layout.window(for: selectedWindowHandle),
           selectedWindow.matchesSearch
        {
            return
        }

        selectedWindowHandle = OverviewSearchFilter.firstMatchingWindow(in: layout)?.handle
    }

    private func mutateLayout(
        for monitorId: Monitor.ID,
        _ mutate: (inout OverviewLayout) -> Void
    ) {
        guard var layout = layoutsByMonitor[monitorId] else { return }
        mutate(&layout)
        layoutsByMonitor[monitorId] = layout
    }

    func setDragTarget(_ target: OverviewDragTarget?, for monitorId: Monitor.ID) {
        for id in layoutsByMonitor.keys {
            mutateLayout(for: id) { layout in
                layout.dragTarget = id == monitorId ? target : nil
            }
        }
    }

    func clearDragTargets() {
        for monitorId in layoutsByMonitor.keys {
            mutateLayout(for: monitorId) { layout in
                layout.dragTarget = nil
            }
        }
    }

    private func viewportFrame(for monitorId: Monitor.ID) -> CGRect {
        guard let wmController,
              let monitor = wmController.workspaceManager.monitor(byId: monitorId)
        else {
            return .zero
        }
        return OverviewLayoutCalculator.viewportFrame(for: monitor.frame)
    }

    func globalPoint(from localPoint: CGPoint, on monitorId: Monitor.ID) -> CGPoint {
        guard let wmController,
              let monitor = wmController.workspaceManager.monitor(byId: monitorId)
        else {
            return localPoint
        }
        return CGPoint(
            x: monitor.frame.minX + localPoint.x,
            y: monitor.frame.minY + localPoint.y
        )
    }
}

extension OverviewViewportProjection {
    func performSelectionNavigation(
        on monitorId: Monitor.ID?,
        resolveNextHandle: (OverviewLayout, WindowHandle?) -> WindowHandle?
    ) -> Bool {
        let targetMonitorId = monitorId ?? activeInteractionMonitorId
        if let targetMonitorId {
            activeInteractionMonitorId = targetMonitorId
        }

        guard let layout = canonicalLayout(preferredMonitorId: targetMonitorId),
              let nextHandle = resolveNextHandle(layout, selectedWindowHandle)
        else { return false }

        let selectionChanged = nextHandle != selectedWindowHandle
        if selectionChanged {
            setSelectedWindowHandle(nextHandle)
        }
        let viewportChanged = revealSelectedWindow(on: targetMonitorId)
        return selectionChanged || viewportChanged
    }

    func adjustScrollOffset(by delta: CGFloat, on monitorId: Monitor.ID) {
        activeInteractionMonitorId = monitorId
        mutateLayout(for: monitorId) { layout in
            let screenFrame = viewportFrame(for: monitorId)
            let nextOffset = layout.scrollOffset + delta
            layout.scrollOffset = OverviewLayoutCalculator.clampedScrollOffset(
                nextOffset,
                layout: layout,
                screenFrame: screenFrame
            )
        }
    }

    func handleScroll(
        delta: CGFloat,
        modifiers: NSEvent.ModifierFlags,
        isPrecise: Bool,
        on monitorId: Monitor.ID
    ) -> Bool {
        activeInteractionMonitorId = monitorId

        if modifiers.contains([.option, .shift]) {
            guard abs(delta) > Self.zoomEpsilon else { return false }
            let step: CGFloat = delta > 0 ? ScrollTuning.zoomStep : -ScrollTuning.zoomStep
            let nextScale = (scale + step).clamped(to: 0.5 ... 1.5)
            guard abs(nextScale - scale) > Self.zoomEpsilon else { return false }
            let anchors = captureSelectedViewportAnchors()
            scale = nextScale
            rebuildProjectedLayouts(preservingSelectedAnchors: anchors)
            return true
        }

        let multiplier = isPrecise
            ? ScrollTuning.preciseScrollMultiplier
            : ScrollTuning.nonPreciseScrollMultiplier
        adjustScrollOffset(by: delta * multiplier, on: monitorId)
        return true
    }
}
