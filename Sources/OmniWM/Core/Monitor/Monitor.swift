import AppKit
import CoreGraphics

struct Monitor: Identifiable, Hashable {
    struct ID: Hashable {
        let displayId: CGDirectDisplayID

        static let fallback = ID(displayId: CGMainDisplayID())
    }

    let id: ID
    let displayId: CGDirectDisplayID
    let frame: CGRect
    let visibleFrame: CGRect
    let hasNotch: Bool

    let name: String

    static func current() -> [Monitor] {
        let monitors = NSScreen.screens.compactMap { screen -> Monitor? in
            guard let displayId = screen.displayId else { return nil }
            var hasNotch = false
            if #available(macOS 12.0, *) {
                hasNotch = screen.safeAreaInsets.top > 0
            }
            return Monitor(
                id: ID(displayId: displayId),
                displayId: displayId,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                hasNotch: hasNotch,
                name: screen.localizedName
            )
        }
        return monitors.sorted { first, second in
            if first.isMain != second.isMain {
                return first.isMain
            }
            if first.frame.minX != second.frame.minX {
                return first.frame.minX < second.frame.minX
            }
            return first.frame.maxY > second.frame.maxY
        }
    }

    static func fallback() -> Monitor {
        let frame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let displayId = NSScreen.main?.displayId ?? CGMainDisplayID()
        var hasNotch = false
        if #available(macOS 12.0, *) {
            hasNotch = NSScreen.main?.safeAreaInsets.top ?? 0 > 0
        }
        return Monitor(
            id: .fallback,
            displayId: displayId,
            frame: frame,
            visibleFrame: frame,
            hasNotch: hasNotch,
            name: "Fallback"
        )
    }
}

extension Monitor {
    enum Orientation: String, Codable, Equatable {
        case horizontal
        case vertical
    }

    var autoOrientation: Orientation {
        frame.width >= frame.height ? .horizontal : .vertical
    }

    var isMain: Bool {
        let mainDisplayId = CGMainDisplayID()
        if mainDisplayId != 0 {
            return displayId == mainDisplayId
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }),
           let displayId = screen.displayId {
            return self.displayId == displayId
        }
        return frame.minX == 0 && frame.minY == 0
    }

    var workspaceAnchorPoint: CGPoint {
        frame.topLeftCorner
    }

    func relation(to monitor: Monitor) -> Orientation {
        let otherYRange = monitor.frame.minY ... monitor.frame.maxY
        let myYRange = frame.minY ... frame.maxY
        return myYRange.overlaps(otherYRange) ? .horizontal : .vertical
    }

    static func sortedMonitors(_ monitors: [Monitor]) -> [Monitor] {
        monitors.sorted {
            if $0.frame.minX != $1.frame.minX {
                return $0.frame.minX < $1.frame.minX
            }
            return $0.frame.maxY > $1.frame.maxY
        }
    }
}

extension NSScreen {
    var displayId: CGDirectDisplayID? {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }
}

extension CGRect {
    var topLeftCorner: CGPoint {
        CGPoint(x: minX, y: maxY)
    }
}

extension CGRect {
    func distanceSquared(to point: CGPoint) -> CGFloat {
        let clampedX = min(max(point.x, minX), maxX)
        let clampedY = min(max(point.y, minY), maxY)
        let dx = point.x - clampedX
        let dy = point.y - clampedY
        return dx * dx + dy * dy
    }
}

extension CGPoint {
    func monitorApproximation(in monitors: [Monitor]) -> Monitor? {
        if let containing = monitors.first(where: { $0.frame.contains(self) }) {
            return containing
        }
        return monitors.min(by: { $0.frame.distanceSquared(to: self) < $1.frame.distanceSquared(to: self) })
    }
}
