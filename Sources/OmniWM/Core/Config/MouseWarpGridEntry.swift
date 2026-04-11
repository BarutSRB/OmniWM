import CoreGraphics

struct MouseWarpGridEntry: Codable, Equatable {
    var name: String
    var x: CGFloat
    var y: CGFloat

    func virtualFrame(for monitor: Monitor) -> CGRect {
        CGRect(x: x, y: y, width: monitor.frame.width, height: monitor.frame.height)
    }
}
