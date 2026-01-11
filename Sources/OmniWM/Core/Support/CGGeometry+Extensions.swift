import Foundation

extension CGFloat {
    func approximatelyEquals(to other: CGFloat, tolerance: CGFloat = 10) -> Bool {
        abs(self - other) < tolerance
    }
}

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        sqrt(pow(x - other.x, 2) + pow(y - other.y, 2))
    }

    func flipY(maxY: CGFloat) -> CGPoint {
        CGPoint(x: x, y: maxY - y)
    }

    func approximatelyEqual(to other: CGPoint, tolerance: CGFloat = 10) -> Bool {
        abs(x - other.x) < tolerance && abs(y - other.y) < tolerance
    }
}

extension CGSize {
    var area: CGFloat { width * height }

    func approximatelyEqual(to other: CGSize, tolerance: CGFloat = 10) -> Bool {
        abs(width - other.width) < tolerance && abs(height - other.height) < tolerance
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
    var topLeftPoint: CGPoint { CGPoint(x: minX, y: minY) }
    var topRightPoint: CGPoint { CGPoint(x: maxX, y: minY) }
    var bottomLeftPoint: CGPoint { CGPoint(x: minX, y: maxY) }
    var bottomRightPoint: CGPoint { CGPoint(x: maxX, y: maxY) }

    func flipY(maxY: CGFloat) -> CGRect {
        CGRect(x: minX, y: maxY - self.maxY, width: width, height: height)
    }

    func approximatelyEqual(to other: CGRect, tolerance: CGFloat = 10) -> Bool {
        abs(origin.x - other.origin.x) < tolerance &&
        abs(origin.y - other.origin.y) < tolerance &&
        abs(width - other.width) < tolerance &&
        abs(height - other.height) < tolerance
    }

    func pushInside(_ bounds: CGRect) -> CGRect {
        var result = self
        if result.minX < bounds.minX { result.origin.x = bounds.minX }
        if result.minY < bounds.minY { result.origin.y = bounds.minY }
        if result.maxX > bounds.maxX { result.origin.x = bounds.maxX - result.width }
        if result.maxY > bounds.maxY { result.origin.y = bounds.maxY - result.height }
        return result
    }

    func inset(by amount: CGFloat, minSize: CGSize) -> CGRect {
        let w = max(minSize.width, width - 2 * amount)
        let h = max(minSize.height, height - 2 * amount)
        return CGRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h)
    }

    func integerRect() -> CGRect {
        CGRect(x: floor(minX), y: floor(minY), width: floor(width), height: floor(height))
    }

    var isFinite: Bool {
        origin.x.isFinite && origin.y.isFinite &&
        size.width.isFinite && size.height.isFinite && !isNull && !isInfinite
    }
}
