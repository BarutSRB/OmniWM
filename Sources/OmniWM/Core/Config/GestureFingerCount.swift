enum GestureFingerCount: Int, CaseIterable, Codable {
    case two = 2
    case three = 3
    case four = 4

    var displayName: String {
        switch self {
        case .two: "2 Fingers"
        case .three: "3 Fingers"
        case .four: "4 Fingers"
        }
    }
}
