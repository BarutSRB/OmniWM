enum ScrollModifierKey: String, CaseIterable, Codable {
    case optionShift
    case controlShift

    var displayName: String {
        switch self {
        case .optionShift: "Option+Shift (⌥⇧)"
        case .controlShift: "Control+Shift (⌃⇧)"
        }
    }
}
