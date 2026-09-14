// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import QuartzCore

@MainActor
final class OverviewLayerRenderer {
    private typealias Colors = OverviewRenderStyle.Colors
    private typealias Metrics = OverviewRenderStyle.Metrics

    let root = CALayer()
    private let backdrop = CALayer()
    private let completionLayer = CALayer()
    private(set) var activeTransition: OverviewNativeTransition?
    private let content = CALayer()
    private let workspaceChrome = CALayer()
    private let cards = CALayer()
    private let dropTarget = CAShapeLayer()
    private let search = CALayer()
    private let searchText = OverviewRenderer.textLayer(size: 16, color: Colors.textDimmed, alignment: .center)
    let caret = CALayer()
    private(set) var windowLayers: [WindowHandle: OverviewWindowLayer] = [:]
    private var chromeLayout: OverviewLayout?
    private var chromeSections: [WorkspaceDescriptor.ID: CALayer] = [:]
    private var contentsScale: CGFloat = 1

    init() {
        root.masksToBounds = true
        root.addSublayer(backdrop)
        root.addSublayer(completionLayer)
        root.addSublayer(content)
        content.addSublayer(workspaceChrome)
        content.addSublayer(cards)
        content.addSublayer(dropTarget)
        root.addSublayer(search)
        search.addSublayer(searchText)
        search.addSublayer(caret)
        search.backgroundColor = Colors.searchBarBackground
        search.borderColor = Colors.searchBarBorder
        search.borderWidth = Metrics.searchBarBorderWidth
        search.cornerRadius = Metrics.searchBarCornerRadius
        caret.backgroundColor = Colors.textWhite
        dropTarget.fillColor = Colors.dropTarget
        dropTarget.strokeColor = Colors.dropTarget
        dropTarget.lineWidth = Metrics.dropOutlineWidth
    }

    func updateLayout(_ layout: OverviewLayout, state: OverviewRenderState, caretAnimated: Bool) {
        OverviewRenderer.withoutAnimation {
            reconcileWindows(layout)
            rebuildWorkspaceChrome(layout)
            updateSearch(layout, state: state, caretAnimated: caretAnimated)
            updateDropTarget(layout)
        }
    }

    func installAnimation(
        _ transition: OverviewNativeTransition,
        layout: OverviewLayout,
        state: OverviewRenderState,
        completion: OverviewAnimationCompletion
    ) {
        activeTransition = transition
        updatePresentation(layout, state: state, replacing: true)
        let animation = transition.makeAnimation(keyPath: "opacity")
        animation.beginTime = completionLayer.convertTime(transition.startTime, from: nil)
        animation.fromValue = 0
        animation.toValue = 1
        animation.delegate = completion
        completionLayer.add(animation, forKey: "overview.completion")
    }

    func cancelAnimation() {
        activeTransition = nil
        completionLayer.removeAnimation(forKey: "overview.completion")
        for layer in [backdrop, workspaceChrome, dropTarget, search] { OverviewLayerMotion.remove(from: layer) }
        for layers in windowLayers.values { layers.cancelAnimation() }
    }

    func windowHit(at point: CGPoint, layout: OverviewLayout) -> OverviewLayout.WindowHit? {
        let displayedContent = content.presentation() ?? content
        let local = CGPoint(x: point.x - displayedContent.frame.minX, y: point.y - displayedContent.frame.minY)
        for section in layout.workspaceSections.reversed() {
            for window in section.windows.reversed() where window.matchesSearch {
                if let close = windowLayers[window.handle]?.hit(at: local) {
                    return OverviewLayout.WindowHit(window: window, isCloseButton: close)
                }
            }
        }
        return nil
    }

    func updatePresentation(_ layout: OverviewLayout, state: OverviewRenderState, replacing: Bool = false) {
        let time = CACurrentMediaTime()
        let motion = activeTransition
            .map { _ in [backdrop, workspaceChrome, dropTarget, search].map(OverviewLayerMotion.init) } ?? []
        OverviewRenderer.withoutAnimation {
            root.frame = state.bounds
            backdrop.frame = root.bounds
            backdrop.backgroundColor = state.palette.backdrop
            backdrop.opacity = Float(state.progress)
            content.frame = root.bounds.offsetBy(dx: 0, dy: -layout.scrollOffset)
            workspaceChrome.opacity = Float(state.progress)
            dropTarget.opacity = Float(state.progress)
            search.opacity = Float(state.progress)
            if state.progress < 1 { caret.removeAnimation(forKey: "blink") }
            let visible = OverviewRenderGeometry.visibleContentRect(
                bounds: state.bounds,
                scrollOffset: layout.scrollOffset
            )
            for section in layout.workspaceSections {
                chromeSections[section.workspaceId]?.isHidden = activeTransition == nil && !OverviewRenderGeometry
                    .shouldRender(
                        frame: OverviewRenderGeometry.sectionCullingFrame(section, progress: state.progress),
                        visibleContentRect: visible
                    )
                for window in section.windows {
                    let frame = window.interpolatedFrame(progress: state.progress)
                    guard let layers = windowLayers[window.handle] else { continue }
                    layers.root.isHidden = !OverviewRenderGeometry.shouldRender(
                        frame: activeTransition == nil ? frame : window.originalFrame.union(window.overviewFrame),
                        visibleContentRect: visible
                    )
                    layers.updateGeometry(
                        window,
                        frame: frame,
                        state: state,
                        transition: activeTransition,
                        replacing: replacing,
                        time: time
                    )
                }
            }
            if let activeTransition {
                for snapshot in motion { snapshot.apply(activeTransition, at: time, replacing: replacing) }
            }
        }
    }

    func updateHover(from previous: WindowHandle?, layout: OverviewLayout, state: OverviewRenderState) {
        OverviewRenderer.withoutAnimation {
            if let previous, previous != state.hoveredWindowHandle, let window = layout.window(for: previous) {
                windowLayers[previous]?.updateEmphasis(window, state: state)
            }
            if let handle = state.hoveredWindowHandle, let window = layout.window(for: handle) {
                windowLayers[handle]?.updateEmphasis(window, state: state)
            }
        }
    }

    func updatePreview(_ frame: OverviewPreviewFrame?, for handle: WindowHandle) {
        windowLayers[handle]?.updatePreview(frame)
    }

    func clearPreviews() {
        caret.removeAnimation(forKey: "blink")
        for layers in windowLayers.values { layers.updatePreview(nil) }
    }

    func updateContentsScale(_ scale: CGFloat) {
        guard scale != contentsScale else { return }
        contentsScale = scale
        OverviewRenderer.withoutAnimation {
            updateScale(in: root)
        }
    }

    private func updateScale(in layer: CALayer) {
        layer.contentsScale = contentsScale
        for sublayer in layer.sublayers ?? [] { updateScale(in: sublayer) }
    }

    private func reconcileWindows(_ layout: OverviewLayout) {
        let handles = Set(layout.workspaceSections.flatMap { $0.windows.map(\.handle) })
        for handle in windowLayers.keys where !handles.contains(handle) {
            if let removed = windowLayers.removeValue(forKey: handle) {
                removed.updatePreview(nil)
                removed.root.removeFromSuperlayer()
            }
        }
        var order: [CALayer] = []
        order.reserveCapacity(handles.count)
        for section in layout.workspaceSections {
            for window in section.windows {
                let layers: OverviewWindowLayer
                if let existing = windowLayers[window.handle] {
                    layers = existing
                } else {
                    layers = OverviewWindowLayer()
                    windowLayers[window.handle] = layers
                    cards.addSublayer(layers.root)
                }
                layers.updateContent(window, contentsScale: contentsScale)
                order.append(layers.root)
            }
        }
        if cards.sublayers?.count != order.count
            || zip(cards.sublayers ?? [], order).contains(where: { $0 !== $1 })
        {
            cards.sublayers = order
        }
    }

    private func rebuildWorkspaceChrome(_ layout: OverviewLayout) {
        guard workspaceChromeNeedsUpdate(layout) else { return }
        chromeLayout = layout
        workspaceChrome.sublayers = nil
        chromeSections.removeAll(keepingCapacity: true)
        for section in layout.workspaceSections {
            let sectionLayer = CALayer()
            workspaceChrome.addSublayer(sectionLayer)
            chromeSections[section.workspaceId] = sectionLayer
            let color = section.isActive ? Colors.workspaceLabelActive : Colors.workspaceLabelInactive
            let label = OverviewRenderer.textLayer(size: 16, color: color)
            label.string = section.name
            label.frame = section.labelFrame
            label.contentsScale = contentsScale
            sectionLayer.addSublayer(label)
            for column in layout.niriColumnsByWorkspace[section.workspaceId] ?? [] {
                let layer = CALayer()
                layer.frame = column.frame
                layer.backgroundColor = Colors.columnBackground
                layer.borderColor = Colors.columnBorder
                layer.borderWidth = 1
                layer.cornerRadius = Metrics.columnCornerRadius
                sectionLayer.addSublayer(layer)
                let frames = column.windowHandles.compactMap { layout.window(for: $0)?.overviewFrame }
                    .sorted { $0.maxY > $1.maxY }
                for (upper, lower) in zip(frames, frames.dropFirst()) {
                    let divider = CALayer()
                    divider.backgroundColor = Colors.columnDivider
                    divider.frame = CGRect(
                        x: column.frame.minX + 8,
                        y: (upper.minY + lower.maxY) / 2 - Metrics.dividerHeight / 2,
                        width: column.frame.width - 16,
                        height: Metrics.dividerHeight
                    )
                    sectionLayer.addSublayer(divider)
                }
            }
        }
    }

    private func workspaceChromeNeedsUpdate(_ layout: OverviewLayout) -> Bool {
        guard let previous = chromeLayout,
              previous.niriColumnsByWorkspace == layout.niriColumnsByWorkspace,
              previous.workspaceSections.count == layout.workspaceSections.count
        else { return true }
        return zip(previous.workspaceSections, layout.workspaceSections).contains { previous, next in
            previous.workspaceId != next.workspaceId || previous.name != next.name
                || previous.isActive != next.isActive || previous.labelFrame != next.labelFrame
                || previous.windows.count != next.windows.count
                || zip(previous.windows, next.windows)
                .contains { pair in pair.0.handle != pair.1.handle || pair.0.overviewFrame != pair.1.overviewFrame }
        }
    }

    private func updateSearch(_ layout: OverviewLayout, state: OverviewRenderState, caretAnimated: Bool) {
        search.frame = layout.searchBarFrame
        let text = state.searchQuery.isEmpty ? "Type to search..." : state.searchQuery
        if searchText.string as? String != text { searchText.string = text }
        searchText.foregroundColor = state.searchQuery.isEmpty ? Colors.textDimmed : Colors.textWhite
        searchText.frame = CGRect(
            x: 12,
            y: (search.bounds.height - 22) / 2,
            width: max(0, search.bounds.width - 24),
            height: 22
        )
        searchText.contentsScale = contentsScale
        let width = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 16)]).width
        caret.frame = CGRect(
            x: min(search.bounds.midX + width / 2 + 2, search.bounds.maxX - 10),
            y: (search.bounds.height - 18) / 2,
            width: 2,
            height: 18
        )
        caret.isHidden = state.searchQuery.isEmpty
        if !caret.isHidden, caretAnimated {
            if caret.animation(forKey: "blink") == nil {
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = 1
                animation.toValue = 0
                animation.duration = .pi / 3
                animation.autoreverses = true
                animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                caret.add(animation, forKey: "blink")
            }
        } else {
            caret.removeAnimation(forKey: "blink")
            caret.opacity = 1
        }
    }

    private func updateDropTarget(_ layout: OverviewLayout) {
        dropTarget.path = nil
        dropTarget.fillColor = Colors.dropTarget
        guard let target = layout.dragTarget else { return }
        let rect: CGRect
        switch target {
        case let .niriWindowInsert(_, handle, position):
            guard let window = layout.window(for: handle) else { return }
            rect = CGRect(
                x: window.overviewFrame.minX,
                y: position == .before ? window.overviewFrame.maxY - Metrics.dropLineHeight : window.overviewFrame.minY,
                width: window.overviewFrame.width,
                height: Metrics.dropLineHeight
            )
        case let .niriColumnInsert(workspaceId, insertIndex):
            guard let zone = layout.niriColumnDropZonesByWorkspace[workspaceId]?
                .first(where: { $0.insertIndex == insertIndex }) else { return }
            rect = CGRect(
                x: zone.frame.midX - Metrics.dropLineWidth / 2,
                y: zone.frame.minY,
                width: Metrics.dropLineWidth,
                height: zone.frame.height
            )
        case let .workspaceMove(workspaceId):
            guard let section = layout.workspaceSections.first(where: { $0.workspaceId == workspaceId }) else { return }
            rect = section.sectionFrame
            dropTarget.fillColor = nil
        }
        dropTarget.path = CGPath(rect: rect, transform: nil)
    }
}
