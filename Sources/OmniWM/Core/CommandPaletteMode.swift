import Foundation

enum CommandPaletteMode: String, CaseIterable, Codable {
    case windows
    case menu
    case clipboard

    var displayName: String {
        switch self {
        case .windows: "Windows"
        case .menu: "Menu"
        case .clipboard: "Clipboard"
        }
    }
}
