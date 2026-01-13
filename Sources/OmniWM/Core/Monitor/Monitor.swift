import AppKit
import CoreGraphics

struct Monitor: Identifiable, Hashable {
    struct ID: Hashable {
        let displayId: CGDirectDisplayID

        static let fallback = ID(displayId: 0)
    }

    let id: ID
    let frame: CGRect
    let visibleFrame: CGRect

    let name: String

    static func current() -> [Monitor] {
        NSScreen.screens.compactMap { screen -> Monitor? in
            guard let displayId = screen.displayId else { return nil }
            return Monitor(
                id: ID(displayId: displayId),
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                name: screen.localizedName
            )
        }
    }

    static func fallback() -> Monitor {
        let frame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return Monitor(
            id: .fallback,
            frame: frame,
            visibleFrame: frame,
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
        frame.minX == 0 && frame.minY == 0
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
