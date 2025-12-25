import CoreGraphics
import Foundation

struct OutputId: Hashable, Codable {
    let displayId: CGDirectDisplayID

    let name: String

    init(displayId: CGDirectDisplayID, name: String) {
        self.displayId = displayId
        self.name = name
    }

    init(from monitor: Monitor) {
        displayId = monitor.id.displayId
        name = monitor.name
    }

    static let none = OutputId(displayId: 0, name: "")
}
