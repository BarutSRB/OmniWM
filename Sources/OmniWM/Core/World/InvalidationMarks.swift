// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct InvalidationDomain: OptionSet {
    let rawValue: UInt8

    static let workspace = InvalidationDomain(rawValue: 1 << 0)
    static let layout = InvalidationDomain(rawValue: 1 << 1)
    static let focus = InvalidationDomain(rawValue: 1 << 2)
    static let fullscreen = InvalidationDomain(rawValue: 1 << 3)

    static let layoutCommit: InvalidationDomain = [.workspace, .layout, .fullscreen]
    static let focusCommit: InvalidationDomain = .focus
}

struct InvalidationMarks: Equatable {
    var workspace: UInt64 = 0
    var layout: UInt64 = 0
    var focus: UInt64 = 0
    var fullscreen: UInt64 = 0

    mutating func record(_ seq: UInt64, domains: InvalidationDomain) {
        if domains.contains(.workspace) { workspace = seq }
        if domains.contains(.layout) { layout = seq }
        if domains.contains(.focus) { focus = seq }
        if domains.contains(.fullscreen) { fullscreen = seq }
    }

    func isCurrent(_ plannedSeq: UInt64, domains: InvalidationDomain) -> Bool {
        if domains.contains(.workspace), workspace > plannedSeq { return false }
        if domains.contains(.layout), layout > plannedSeq { return false }
        if domains.contains(.focus), focus > plannedSeq { return false }
        if domains.contains(.fullscreen), fullscreen > plannedSeq { return false }
        return true
    }

    func merged(with other: InvalidationMarks) -> InvalidationMarks {
        InvalidationMarks(
            workspace: max(workspace, other.workspace),
            layout: max(layout, other.layout),
            focus: max(focus, other.focus),
            fullscreen: max(fullscreen, other.fullscreen)
        )
    }
}
