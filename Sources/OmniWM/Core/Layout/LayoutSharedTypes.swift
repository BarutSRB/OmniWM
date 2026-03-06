import AppKit
import Foundation

enum CenterFocusedColumn: String, CaseIterable, Codable, Identifiable {
    case never
    case always
    case onOverflow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .never: "Never"
        case .always: "Always"
        case .onOverflow: "On Overflow"
        }
    }
}

enum SingleWindowAspectRatio: String, CaseIterable, Codable, Identifiable {
    case none
    case ratio16x9 = "16:9"
    case ratio4x3 = "4:3"
    case ratio21x9 = "21:9"
    case square = "1:1"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "None (Fill)"
        case .ratio16x9: "16:9"
        case .ratio4x3: "4:3"
        case .ratio21x9: "21:9"
        case .square: "Square"
        }
    }

    var ratio: CGFloat? {
        switch self {
        case .none: nil
        case .ratio16x9: 16.0 / 9.0
        case .ratio4x3: 4.0 / 3.0
        case .ratio21x9: 21.0 / 9.0
        case .square: 1.0
        }
    }
}

struct Struts {
    var left: CGFloat = 0
    var right: CGFloat = 0
    var top: CGFloat = 0
    var bottom: CGFloat = 0

    static let zero = Struts()
}

func computeWorkingArea(
    parentArea: CGRect,
    scale: CGFloat,
    struts: Struts
) -> CGRect {
    var workingArea = parentArea

    workingArea.size.width = max(0, workingArea.size.width - struts.left - struts.right)
    workingArea.origin.x += struts.left

    workingArea.size.height = max(0, workingArea.size.height - struts.top - struts.bottom)
    workingArea.origin.y += struts.bottom

    let physicalX = ceil(workingArea.origin.x * scale) / scale
    let physicalY = ceil(workingArea.origin.y * scale) / scale

    let xDiff = min(workingArea.size.width, physicalX - workingArea.origin.x)
    let yDiff = min(workingArea.size.height, physicalY - workingArea.origin.y)

    workingArea.size.width -= xDiff
    workingArea.size.height -= yDiff
    workingArea.origin.x = physicalX
    workingArea.origin.y = physicalY

    return workingArea
}

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
