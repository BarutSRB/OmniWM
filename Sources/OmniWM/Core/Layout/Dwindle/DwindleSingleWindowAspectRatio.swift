// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CoreGraphics

enum DwindleSingleWindowAspectRatio: String, CaseIterable, Codable, Identifiable {
    case fill = "fill"
    case ratio16x9 = "16:9"
    case ratio4x3 = "4:3"
    case ratio21x9 = "21:9"
    case square = "1:1"
    case ratio3x2 = "3:2"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fill: "Fill Screen"
        case .ratio16x9: "16:9 (Widescreen)"
        case .ratio4x3: "4:3 (Standard)"
        case .ratio21x9: "21:9 (Ultrawide)"
        case .square: "1:1 (Square)"
        case .ratio3x2: "3:2"
        }
    }

    var size: CGSize {
        switch self {
        case .fill: CGSize(width: 0, height: 0)
        case .ratio16x9: CGSize(width: 16, height: 9)
        case .ratio4x3: CGSize(width: 4, height: 3)
        case .ratio21x9: CGSize(width: 21, height: 9)
        case .square: CGSize(width: 1, height: 1)
        case .ratio3x2: CGSize(width: 3, height: 2)
        }
    }

    var isFillScreen: Bool {
        self == .fill
    }
}
