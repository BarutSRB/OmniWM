// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class TabRailWindow: NSPanel {
    private let railView: TabRailView
    let hoverCard: TabRailHoverCardWindow
    private let surfaceID: String
    private let surfaceCoordinator = SurfaceCoordinator.shared
    private var lastFrame: CGRect?
    private var lastActiveWindowId: Int?
    private var currentInfo: TabRailInfo?
    private var style: TabRailStyle = .compact
    private var animationGeometryNeedsAccessibilityRefresh = false
    private var registeredSurfaceWindowNumber: Int?
    private var accessibilityDisplayObserver: NSObjectProtocol?

    var onSelect: ((TabRailInfo, Int, WindowToken?) -> Void)?

    init(
        owner: TabRailOwner, workspaceId: WorkspaceDescriptor.ID, motionPolicy: MotionPolicy,
        appInfoCache: AppInfoCache = AppInfoCache()
    ) {
        surfaceID = Self.surfaceID(workspaceId: workspaceId, owner: owner)
        railView = TabRailView(frame: .zero, motionPolicy: motionPolicy, appInfoCache: appInfoCache)
        hoverCard = TabRailHoverCardWindow()

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
        railView.onHoverChange = { [weak self] tab, itemRect in
            self?.updateHoverCard(tab: tab, itemRect: itemRect)
        }
        contentView = railView

        accessibilityDisplayObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak railView, weak hoverCard] _ in
            Task { @MainActor [weak railView, weak hoverCard] in
                railView?.refreshAppearance()
                hoverCard?.refreshAppearance()
            }
        }
    }

    override func close() {
        dismissHover()
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

    func update(info: TabRailInfo, forceOrdering: Bool, style: TabRailStyle = .compact) {
        let frame = Self.railFrame(for: info.visibleTileFrame, tabCount: info.tabCount, style: style)
        if self.style != style || frame != lastFrame || frame != self.frame || !isVisible {
            dismissHover()
        }
        self.style = style
        currentInfo = info
        let clampedActiveVisualIndex = min(max(0, info.activeVisualIndex), max(0, info.tabCount - 1))
        guard frame.width > 1, frame.height > 1 else {
            railView.update(tabs: info.normalizedTabs, activeVisualIndex: clampedActiveVisualIndex, style: style)
            dismissHover()
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
        railView.update(tabs: info.normalizedTabs, activeVisualIndex: clampedActiveVisualIndex, style: style)

        if accessibilityGeometryChanged {
            railView.refreshAccessibilityFrames()
        }
        animationGeometryNeedsAccessibilityRefresh = false

        let wasVisible = isVisible
        if TabRailOrderingPolicy.shouldOrderFront(
            forceOrdering: forceOrdering,
            wasVisible: wasVisible,
            lastActiveWindowId: lastActiveWindowId,
            activeWindowId: info.activeWindowId
        ) {
            orderFront(nil)
        }
        syncSurfaceRegistration()
        lastActiveWindowId = info.activeWindowId
    }

    func updateAnimationGeometry(_ command: TabRailGeometryCommand) {
        guard let currentInfo, currentInfo.key == command.key else { return }
        let frame = Self.railFrame(for: command.visibleTileFrame, tabCount: currentInfo.tabCount, style: style)
        guard frame.width > 1, frame.height > 1 else {
            dismissHover()
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

        dismissHover()
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

    private func dismissHover() {
        railView.invalidateHover()
        hoverCard.hide()
    }

    private func updateHoverCard(tab: TabRailTabInfo?, itemRect: CGRect?) {
        guard let tab, let itemRect, let currentInfo, isVisible else {
            hoverCard.hide()
            return
        }
        let screenFrame = screen?.visibleFrame
            ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
        guard let screenFrame else {
            hoverCard.hide()
            return
        }
        let cardFrame = TabRailHoverCardPlacement.frame(
            railFrame: lastFrame ?? frame,
            itemRect: itemRect,
            cardSize: TabRailMetrics.hoverCardSize,
            visibleFrame: screenFrame,
            gap: TabRailMetrics.hoverCardGap
        )
        hoverCard.show(tab: tab, tabCount: currentInfo.tabCount, frame: cardFrame)
    }

    private static func railFrame(for visibleTileFrame: CGRect, tabCount: Int, style: TabRailStyle) -> CGRect {
        guard tabCount > 0,
              TabRailManager.isRenderable(visibleTileFrame: visibleTileFrame)
        else {
            return .zero
        }
        let width = style.hitWidth
        let height = style.fittedHeight(tabCount: tabCount, availableHeight: visibleTileFrame.height)
        guard height > 1 else { return .zero }
        let x = visibleTileFrame.minX - (width - style.reservedWidth)
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
