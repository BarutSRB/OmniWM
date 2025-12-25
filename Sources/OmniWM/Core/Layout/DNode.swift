import ApplicationServices
import CoreGraphics
import Foundation

struct WindowHandle: Hashable {
    let id: UUID
    let pid: pid_t
    let axElement: AXUIElement
}
