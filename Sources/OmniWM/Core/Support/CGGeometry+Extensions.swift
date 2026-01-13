import Foundation

extension CGPoint {
    func flipY(maxY: CGFloat) -> CGPoint {
        CGPoint(x: x, y: maxY - y)
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    func approximatelyEqual(to other: CGRect, tolerance: CGFloat = 10) -> Bool {
        abs(origin.x - other.origin.x) < tolerance &&
        abs(origin.y - other.origin.y) < tolerance &&
        abs(width - other.width) < tolerance &&
        abs(height - other.height) < tolerance
    }
}
