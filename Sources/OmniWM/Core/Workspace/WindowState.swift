import Foundation

enum LayoutReason: Codable, Equatable {
    case standard

    case macosMinimized

    case macosFullscreen

    case macosHiddenApp
}

enum ParentKind: Codable, Equatable {
    case tilingContainer

    case floating
}
