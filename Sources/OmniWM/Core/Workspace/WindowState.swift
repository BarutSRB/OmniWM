// SPDX-License-Identifier: GPL-2.0-only
import Foundation

enum LayoutReason: Codable, Equatable {
    case standard
    case macosHiddenApp
    case nativeFullscreen
}

enum ParentKind: Codable, Equatable {
    case tilingContainer
}
