// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreGraphics
import CoreText
import Foundation

struct OverviewRenderState {
    let searchQuery: String
    let selectedWindowHandle: WindowHandle?
    let hoveredWindowHandle: WindowHandle?
    let closeButtonHovered: Bool
    let progress: Double
    let bounds: CGRect
    let palette: OverviewRenderPalette
}

enum OverviewRenderer {
    private typealias Colors = OverviewRenderStyle.Colors
    private typealias Metrics = OverviewRenderStyle.Metrics

    static func render(
        context: CGContext,
        layout: OverviewLayout,
        thumbnails: [Int: CGImage],
        textLineCache: inout OverviewTextLineCache,
        state: OverviewRenderState
    ) {
        let progress = state.progress
        let bounds = state.bounds
        let palette = state.palette
        let searchQuery = state.searchQuery
        let alpha = CGFloat(progress)

        context.saveGState()
        context.setAlpha(alpha)
        context.setFillColor(palette.backdrop)
        context.fill(bounds)
        context.restoreGState()

        guard progress > 0 else { return }

        renderContent(
            context: context,
            layout: layout,
            thumbnails: thumbnails,
            textLineCache: &textLineCache,
            state: state
        )

        renderSearchBar(
            context: context,
            frame: layout.searchBarFrame,
            searchQuery: searchQuery,
            alpha: alpha,
            textLineCache: &textLineCache
        )
    }

    private static func renderContent(
        context: CGContext,
        layout: OverviewLayout,
        thumbnails: [Int: CGImage],
        textLineCache: inout OverviewTextLineCache,
        state: OverviewRenderState
    ) {
        let scrollOffset = layout.scrollOffset
        let visibleContentRect = OverviewRenderGeometry.visibleContentRect(
            bounds: state.bounds,
            scrollOffset: scrollOffset
        )

        context.saveGState()
        context.translateBy(x: 0, y: -scrollOffset)

        for section in layout.workspaceSections {
            if !OverviewRenderGeometry.shouldRender(
                frame: OverviewRenderGeometry.sectionCullingFrame(section, progress: state.progress),
                visibleContentRect: visibleContentRect
            ) {
                continue
            }

            renderWorkspaceLabel(
                context: context,
                section: section,
                alpha: CGFloat(state.progress),
                textLineCache: &textLineCache
            )

            if let columns = layout.niriColumnsByWorkspace[section.workspaceId] {
                renderNiriColumns(
                    context: context,
                    columns: columns,
                    layout: layout,
                    alpha: CGFloat(state.progress),
                    visibleContentRect: visibleContentRect
                )
            }

            renderWindows(
                section.windows,
                renderer: OverviewWindowRenderer(context: context, state: state),
                thumbnails: thumbnails,
                visibleContentRect: visibleContentRect,
                textLineCache: &textLineCache
            )
        }

        if let dragTarget = layout.dragTarget {
            renderDragTarget(
                context: context,
                layout: layout,
                dragTarget: dragTarget,
                alpha: CGFloat(state.progress)
            )
        }

        context.restoreGState()
    }

    static func borderColor(
        isSelected: Bool,
        isHovered: Bool,
        palette: OverviewRenderPalette
    ) -> CGColor {
        if isSelected {
            return palette.selectedBorder
        }
        if isHovered {
            return palette.hoveredBorder
        }
        return palette.normalBorder
    }

    private static func renderNiriColumns(
        context: CGContext,
        columns: [OverviewNiriColumn],
        layout: OverviewLayout,
        alpha: CGFloat,
        visibleContentRect: CGRect
    ) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(alpha)

        for column in columns {
            let frame = column.frame
            if !OverviewRenderGeometry.shouldRender(frame: frame, visibleContentRect: visibleContentRect) {
                continue
            }

            let path = CGPath(
                roundedRect: frame,
                cornerWidth: Metrics.columnCornerRadius,
                cornerHeight: Metrics.columnCornerRadius,
                transform: nil
            )
            context.addPath(path)
            context.setFillColor(Colors.columnBackground)
            context.fillPath()

            context.addPath(path)
            context.setStrokeColor(Colors.columnBorder)
            context.setLineWidth(1.0)
            context.strokePath()

            if column.windowHandles.count > 1 {
                let frames = column.windowHandles.compactMap { layout.window(for: $0)?.overviewFrame }
                let sorted = frames.sorted { $0.maxY > $1.maxY }
                for i in 0 ..< (sorted.count - 1) {
                    let upper = sorted[i]
                    let lower = sorted[i + 1]
                    let y = (upper.minY + lower.maxY) / 2
                    let divider = CGRect(
                        x: frame.minX + 8,
                        y: y - Metrics.dividerHeight / 2,
                        width: frame.width - 16,
                        height: Metrics.dividerHeight
                    )
                    context.setFillColor(Colors.columnDivider)
                    context.fill(divider)
                }
            }
        }
    }

    private static func renderDragTarget(
        context: CGContext,
        layout: OverviewLayout,
        dragTarget: OverviewDragTarget,
        alpha: CGFloat
    ) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(alpha)

        switch dragTarget {
        case let .niriWindowInsert(_, targetHandle, position):
            guard let window = layout.window(for: targetHandle) else { return }
            let frame = window.overviewFrame
            let y = position == .before ? frame.maxY - Metrics.dropLineHeight : frame.minY
            let lineFrame = CGRect(
                x: frame.minX,
                y: y,
                width: frame.width,
                height: Metrics.dropLineHeight
            )
            context.setFillColor(Colors.dropTarget)
            context.fill(lineFrame)

        case let .niriColumnInsert(workspaceId, insertIndex):
            guard let zones = layout.niriColumnDropZonesByWorkspace[workspaceId] else { return }
            guard let zone = zones.first(where: { $0.insertIndex == insertIndex }) else { return }
            let x = zone.frame.midX - Metrics.dropLineWidth / 2
            let lineFrame = CGRect(
                x: x,
                y: zone.frame.minY,
                width: Metrics.dropLineWidth,
                height: zone.frame.height
            )
            context.setFillColor(Colors.dropTarget)
            context.fill(lineFrame)

        case let .workspaceMove(workspaceId):
            guard let section = layout.workspaceSections.first(where: { $0.workspaceId == workspaceId }) else { return }
            context.setStrokeColor(Colors.dropTarget)
            context.setLineWidth(Metrics.dropOutlineWidth)
            context.stroke(section.sectionFrame)
        }
    }

    private static func renderWorkspaceLabel(
        context: CGContext,
        section: OverviewWorkspaceSection,
        alpha: CGFloat,
        textLineCache: inout OverviewTextLineCache
    ) {
        let color = section.isActive ? Colors.workspaceLabelActiveNS : Colors.workspaceLabelInactiveNS
        let role: OverviewTextLineCache.Role = section.isActive ? .workspaceActive : .workspaceInactive
        let key = OverviewTextLineCache.Key(role: role, text: section.name, widthBucket: 0)
        let font = textLineCache.workspaceLabelFont
        let line = textLineCache.line(for: key) {
            OverviewTextLineCache.makeLine(text: section.name, font: font, color: color)
        }

        context.saveGState()
        context.setAlpha(alpha)
        context.textMatrix = .identity
        context.translateBy(x: section.labelFrame.minX, y: section.labelFrame.minY + 8)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func renderWindows(
        _ windows: [OverviewWindowItem],
        renderer: OverviewWindowRenderer,
        thumbnails: [Int: CGImage],
        visibleContentRect: CGRect,
        textLineCache: inout OverviewTextLineCache
    ) {
        for window in windows {
            let frame = window.interpolatedFrame(progress: renderer.state.progress)
            guard OverviewRenderGeometry.shouldRender(frame: frame, visibleContentRect: visibleContentRect)
            else { continue }
            renderer.render(
                window: window,
                frame: frame,
                thumbnail: thumbnails[window.windowId],
                textLineCache: &textLineCache
            )
        }
    }

    private static func renderSearchBar(
        context: CGContext,
        frame: CGRect,
        searchQuery: String,
        alpha: CGFloat,
        textLineCache: inout OverviewTextLineCache
    ) {
        let path = CGPath(
            roundedRect: frame,
            cornerWidth: Metrics.searchBarCornerRadius,
            cornerHeight: Metrics.searchBarCornerRadius,
            transform: nil
        )

        context.saveGState()
        context.setAlpha(alpha)
        context.addPath(path)
        context.setFillColor(Colors.searchBarBackground)
        context.fillPath()

        context.addPath(path)
        context.setStrokeColor(Colors.searchBarBorder)
        context.setLineWidth(Metrics.searchBarBorderWidth)
        context.strokePath()

        let displayText = searchQuery.isEmpty ? "Type to search..." : searchQuery
        let textColor = searchQuery.isEmpty ? Colors.textDimmedNS : Colors.textWhiteNS

        let role: OverviewTextLineCache.Role = searchQuery.isEmpty ? .searchPlaceholder : .searchQuery
        let key = OverviewTextLineCache.Key(role: role, text: displayText, widthBucket: 0)
        let font = textLineCache.searchFont
        let line = textLineCache.line(for: key) {
            OverviewTextLineCache.makeLine(text: displayText, font: font, color: textColor)
        }

        let textBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let textX = frame.midX - textBounds.width / 2
        let textY = frame.midY - textBounds.height / 2

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: textX, y: textY)
        CTLineDraw(line, context)
        context.restoreGState()
        context.restoreGState()

        if !searchQuery.isEmpty {
            let cursorX = textX + textBounds.width + 2
            let cursorHeight: CGFloat = 18
            let cursorY = frame.midY - cursorHeight / 2

            let time = CACurrentMediaTime()
            let cursorAlpha = (sin(time * 3) + 1) / 2

            context.saveGState()
            context.setAlpha(alpha * CGFloat(cursorAlpha))
            context.setFillColor(Colors.textWhite)
            context.fill(CGRect(x: cursorX, y: cursorY, width: 2, height: cursorHeight))
            context.restoreGState()
        }
    }
}
