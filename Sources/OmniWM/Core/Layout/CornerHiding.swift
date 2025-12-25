import AppKit
import Foundation

enum OptimalHideCorner {
    case bottomLeftCorner
    case bottomRightCorner
}

enum CornerHidingService {
    static func calculateOptimalCorners(for monitors: [Monitor]) -> [Monitor.ID: OptimalHideCorner] {
        var result: [Monitor.ID: OptimalHideCorner] = [:]
        for monitor in monitors {
            let frame = monitor.frame
            let xOff = frame.width * 0.1
            let yOff = frame.height * 0.1

            let bottomRight = frame.bottomRightCorner
            let bottomLeft = frame.bottomLeftCorner

            let brc1 = bottomRight + CGPoint(x: 2, y: yOff)
            let brc2 = bottomRight + CGPoint(x: -xOff, y: -2)
            let brc3 = bottomRight + CGPoint(x: 2, y: -2)

            let blc1 = bottomLeft + CGPoint(x: -2, y: yOff)
            let blc2 = bottomLeft + CGPoint(x: xOff, y: -2)
            let blc3 = bottomLeft + CGPoint(x: -2, y: -2)

            func contains(_ monitor: Monitor, _ point: CGPoint) -> Int {
                monitor.frame.contains(point) ? 1 : 0
            }

            let important = 10
            let blcScore = monitors.reduce(0) { total, candidate in
                total + contains(candidate, blc1) + contains(candidate, blc2) + important * contains(candidate, blc3)
            }
            let brcScore = monitors.reduce(0) { total, candidate in
                total + contains(candidate, brc1) + contains(candidate, brc2) + important * contains(candidate, brc3)
            }

            let corner: OptimalHideCorner = blcScore < brcScore ? .bottomLeftCorner : .bottomRightCorner
            result[monitor.id] = corner
        }
        return result
    }
}
