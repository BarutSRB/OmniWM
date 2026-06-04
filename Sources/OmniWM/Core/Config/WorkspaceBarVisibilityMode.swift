import Foundation

enum WorkspaceBarVisibilityMode: String, CaseIterable, Identifiable {
    case always
    case holdKey

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .always: "Always"
        case .holdKey: "While Hotkey Is Pressed"
        }
    }
}
