import Foundation

enum NiriSizeChange: Codable, Equatable, Hashable {
    case setFixed(CGFloat)
    case setProportion(CGFloat)
    case adjustFixed(CGFloat)
    case adjustProportion(CGFloat)

    static let maxPixels: CGFloat = 100_000
    static let maxProportion: CGFloat = 10_000
}
