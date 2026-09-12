// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreGraphics
import CoreText
import Foundation

struct OverviewTextLineCache {
    enum Role: Hashable {
        case appName
        case groupBadge
        case searchPlaceholder
        case searchQuery
        case title
        case workspaceActive
        case workspaceInactive
    }

    struct Key: Hashable {
        let role: Role
        let text: String
        let widthBucket: Int
    }

    private static let maximumEntryCount = 512
    private var lines: [Key: CTLine] = [:]
    let appNameFont = CTFontCreateWithName("SF Pro Text" as CFString, 10, nil)
    let groupBadgeFont = CTFontCreateWithName("SF Pro Text" as CFString, 11, nil)
    let searchFont = CTFontCreateWithName("SF Pro Text" as CFString, 16, nil)
    let titleFont = CTFontCreateWithName("SF Pro Text" as CFString, 12, nil)
    let workspaceLabelFont = CTFontCreateWithName("SF Pro Display" as CFString, 16, nil)

    var entryCount: Int {
        lines.count
    }

    mutating func line(for key: Key, make: () -> CTLine) -> CTLine {
        if let line = lines[key] {
            return line
        }
        if lines.count >= Self.maximumEntryCount {
            lines.removeAll(keepingCapacity: true)
        }
        let line = make()
        lines[key] = line
        return line
    }

    mutating func removeAll() {
        lines.removeAll(keepingCapacity: true)
    }

    static func makeLine(text: String, font: CTFont, color: NSColor) -> CTLine {
        CTLineCreateWithAttributedString(
            NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .foregroundColor: color
                ]
            )
        )
    }

    static func makeTruncatedLine(
        text: String,
        font: CTFont,
        color: NSColor,
        maxWidth: CGFloat
    ) -> CTLine {
        let line = makeLine(text: text, font: font, color: color)
        guard CTLineGetTypographicBounds(line, nil, nil, nil) > Double(maxWidth) else {
            return line
        }
        let token = makeLine(text: "…", font: font, color: color)
        return CTLineCreateTruncatedLine(line, Double(maxWidth), .end, token) ?? token
    }
}
