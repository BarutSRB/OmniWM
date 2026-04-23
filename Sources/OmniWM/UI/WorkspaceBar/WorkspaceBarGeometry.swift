// SPDX-License-Identifier: GPL-2.0-only
import CoreGraphics

struct WorkspaceBarGeometry: Equatable {
    let effectivePosition: WorkspaceBarPosition
    let menuBarHeight: CGFloat
    let barHeight: CGFloat
    let reservedTopInset: CGFloat

    static func resolve(
        monitor: Monitor,
        resolved: ResolvedBarSettings,
        isVisible: Bool,
        menuBarHeight: CGFloat? = nil
    ) -> WorkspaceBarGeometry {
        let resolvedMenuBarHeight = menuBarHeight ?? self.menuBarHeight(for: monitor)
        let effectivePosition = effectivePosition(for: monitor, resolved: resolved)
        let configuredBarHeight = max(0, CGFloat(resolved.height))
        let barHeight = max(resolvedMenuBarHeight, configuredBarHeight)
        let reservedTopInset: CGFloat

        guard isVisible, resolved.reserveLayoutSpace else {
            reservedTopInset = 0
            return WorkspaceBarGeometry(
                effectivePosition: effectivePosition,
                menuBarHeight: resolvedMenuBarHeight,
                barHeight: barHeight,
                reservedTopInset: reservedTopInset
            )
        }

        if effectivePosition == .belowMenuBar {
            reservedTopInset = barHeight
        } else {
            reservedTopInset = configuredBarHeight
        }

        return WorkspaceBarGeometry(
            effectivePosition: effectivePosition,
            menuBarHeight: resolvedMenuBarHeight,
            barHeight: barHeight,
            reservedTopInset: reservedTopInset
        )
    }

    func frame(
        fittingWidth: CGFloat,
        monitor: Monitor,
        resolved: ResolvedBarSettings
    ) -> CGRect {
        let width = max(fittingWidth, 300)
        var x = monitor.frame.midX - width / 2
        var y = effectivePosition == .belowMenuBar ? monitor.visibleFrame.maxY - barHeight : monitor.visibleFrame.maxY

        x += CGFloat(resolved.xOffset)
        y += CGFloat(resolved.yOffset)

        return CGRect(x: x, y: y, width: width, height: barHeight)
    }

    static func effectivePosition(
        for monitor: Monitor,
        resolved: ResolvedBarSettings
    ) -> WorkspaceBarPosition {
        if monitor.hasNotch,
           resolved.notchAware,
           resolved.position == .overlappingMenuBar
        {
            return .belowMenuBar
        }
        return resolved.position
    }

    static func menuBarHeight(for monitor: Monitor) -> CGFloat {
        let height = monitor.frame.maxY - monitor.visibleFrame.maxY
        return height > 0 ? height : 28
    }
}
