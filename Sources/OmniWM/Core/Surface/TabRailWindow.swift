// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

@MainActor
final class TabRailWindow: NSPanel {
    private let railView: TabRailView
    private let surfaceID: String
    private let surfaceCoordinator = SurfaceCoordinator.shared
    private var lastFrame: CGRect?
    private var lastActiveWindowId: Int?
    private var currentInfo: TabRailInfo?
    private var animationGeometryNeedsAccessibilityRefresh = false
    private var registeredSurfaceWindowNumber: Int?
    private var accessibilityDisplayObserver: NSObjectProtocol?

    var onSelect: ((TabRailInfo, Int, WindowToken?) -> Void)?

    init(owner: TabRailOwner, workspaceId: WorkspaceDescriptor.ID) {
        surfaceID = Self.surfaceID(workspaceId: workspaceId, owner: owner)
        railView = TabRailView(frame: .zero)

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
        collectionBehavior = [.managed, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false

        railView.onSelect = { [weak self] visualIndex in
            guard let self, let currentInfo else { return }
            let token = currentInfo.tabs.first(where: { $0.visualIndex == visualIndex })?.token
            self.onSelect?(currentInfo, visualIndex, token)
        }
        contentView = railView

        accessibilityDisplayObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak railView] _ in
            Task { @MainActor [weak railView] in
                railView?.needsDisplay = true
            }
        }
    }

    override func close() {
        if let accessibilityDisplayObserver {
            NotificationCenter.default.removeObserver(accessibilityDisplayObserver)
            self.accessibilityDisplayObserver = nil
        }
        surfaceCoordinator.unregister(id: surfaceID)
        registeredSurfaceWindowNumber = nil
        super.close()
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    func update(info: TabRailInfo, forceOrdering: Bool) {
        currentInfo = info
        let clampedActiveVisualIndex = min(max(0, info.activeVisualIndex), max(0, info.tabCount - 1))
        railView.update(tabs: info.tabs, activeVisualIndex: clampedActiveVisualIndex)

        let frame = Self.railFrame(for: info.visibleTileFrame, tabCount: info.tabCount)
        guard frame.width > 1, frame.height > 1 else {
            orderOut(nil)
            lastFrame = nil
            surfaceCoordinator.unregister(id: surfaceID)
            registeredSurfaceWindowNumber = nil
            return
        }

        let accessibilityGeometryChanged = animationGeometryNeedsAccessibilityRefresh || self.frame != frame
        if lastFrame != frame || self.frame != frame {
            setFrame(frame, display: false)
            railView.frame = CGRect(origin: .zero, size: frame.size)
            lastFrame = frame
        }

        if accessibilityGeometryChanged {
            railView.refreshAccessibilityFrames()
        }
        animationGeometryNeedsAccessibilityRefresh = false

        let wasVisible = isVisible
        if forceOrdering || !wasVisible {
            orderFront(nil)
        }
        syncSurfaceRegistration()

        if let targetWid = info.activeWindowId,
           forceOrdering || lastActiveWindowId != targetWid || !wasVisible
        {
            let wid = UInt32(windowNumber)
            SkyLight.shared.orderWindow(wid, relativeTo: UInt32(targetWid))
        }
        lastActiveWindowId = info.activeWindowId
    }

    func updateAnimationGeometry(_ command: TabRailGeometryCommand) {
        guard let currentInfo, currentInfo.key == command.key else { return }
        let frame = Self.railFrame(for: command.visibleTileFrame, tabCount: currentInfo.tabCount)
        guard frame.width > 1, frame.height > 1 else {
            if isVisible {
                orderOut(nil)
            }
            if registeredSurfaceWindowNumber != nil {
                surfaceCoordinator.unregister(id: surfaceID)
                registeredSurfaceWindowNumber = nil
            }
            lastFrame = nil
            return
        }
        guard frame != lastFrame || frame != self.frame else { return }

        animationGeometryNeedsAccessibilityRefresh = true
        if frame.size == self.frame.size {
            SkyLight.shared.transactionMove(
                UInt32(windowNumber),
                origin: ScreenCoordinateSpace.toWindowServer(rect: frame).origin
            )
        } else {
            railView.performWithoutAccessibilityGeometryUpdates {
                setFrame(frame, display: false)
                railView.frame = CGRect(origin: .zero, size: frame.size)
                railView.needsDisplay = true
            }
        }
        lastFrame = frame

        guard !isVisible else { return }
        orderFront(nil)
        syncSurfaceRegistration()
        if let targetWid = currentInfo.activeWindowId {
            SkyLight.shared.orderWindow(UInt32(windowNumber), relativeTo: UInt32(targetWid))
        }
    }

    private static func railFrame(for visibleTileFrame: CGRect, tabCount: Int) -> CGRect {
        guard tabCount > 0,
              TabRailManager.isRenderable(visibleTileFrame: visibleTileFrame)
        else {
            return .zero
        }
        let width = max(TabRailMetrics.hitWidth, TabRailMetrics.totalWidth)
        let height = TabRailLayout.fittedHeight(tabCount: tabCount, availableHeight: visibleTileFrame.height)
        guard height > 1 else { return .zero }
        let x = visibleTileFrame.minX - (width - TabRailMetrics.totalWidth)
        let y = visibleTileFrame.minY + (visibleTileFrame.height - height) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func syncSurfaceRegistration() {
        let currentWindowNumber = windowNumber
        guard currentWindowNumber > 0 else {
            surfaceCoordinator.unregister(id: surfaceID)
            registeredSurfaceWindowNumber = nil
            return
        }
        guard registeredSurfaceWindowNumber != currentWindowNumber else { return }

        surfaceCoordinator.registerWindowNumber(
            id: surfaceID,
            windowNumber: currentWindowNumber,
            frameProvider: { [weak self] in
                self?.lastFrame
            },
            visibilityProvider: { [weak self] in
                self?.isVisible == true && self?.lastFrame != nil
            },
            policy: SurfacePolicy(
                kind: .tabRail,
                hitTestPolicy: .interactive,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
        registeredSurfaceWindowNumber = currentWindowNumber
    }

    private static func surfaceID(workspaceId: WorkspaceDescriptor.ID, owner: TabRailOwner) -> String {
        "tab-rail-\(workspaceId.uuidString)-\(owner.surfaceIdentifier)"
    }
}
