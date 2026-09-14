// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

enum ColumnDisplay: Codable, Equatable, Sendable {
    case normal

    case tabbed
}

enum SizingMode: Codable, Equatable, Sendable {
    case normal

    case maximized

    case fullscreen
}

enum ProportionalSize: Codable, Equatable, Sendable {
    case proportion(CGFloat)

    case fixed(CGFloat)

    var value: CGFloat {
        switch self {
        case let .proportion(proportion): proportion
        case let .fixed(size): size
        }
    }

    var isProportion: Bool {
        if case .proportion = self { return true }
        return false
    }

    var isFixed: Bool {
        if case .fixed = self { return true }
        return false
    }

    static let `default` = ProportionalSize.proportion(1.0)
}

enum WeightedSize: Codable, Equatable, Sendable {
    case auto(weight: CGFloat)

    case fixed(CGFloat)

    case preset(Int)

    var weight: CGFloat {
        switch self {
        case let .auto(weight): weight
        case .fixed,
             .preset: 0
        }
    }

    var isAuto: Bool {
        if case .auto = self { return true }
        return false
    }

    var isFixed: Bool {
        if case .fixed = self { return true }
        return false
    }

    var presetIndex: Int? {
        if case let .preset(index) = self { return index }
        return nil
    }

    static let `default` = WeightedSize.auto(weight: 1.0)
}

struct WindowSizeConstraints: Equatable, Sendable {
    var minSize: CGSize

    var maxSize: CGSize

    var isFixed: Bool

    init(minSize: CGSize, maxSize: CGSize, isFixed: Bool) {
        let normalizedMinWidth = Self.normalizedMinDimension(minSize.width)
        let normalizedMinHeight = Self.normalizedMinDimension(minSize.height)
        let normalizedMaxWidth = Self.normalizedMaxDimension(
            maxSize.width,
            minimum: normalizedMinWidth
        )
        let normalizedMaxHeight = Self.normalizedMaxDimension(
            maxSize.height,
            minimum: normalizedMinHeight
        )

        if isFixed {
            let fixedWidth = normalizedMaxWidth > 0 ? normalizedMaxWidth : normalizedMinWidth
            let fixedHeight = normalizedMaxHeight > 0 ? normalizedMaxHeight : normalizedMinHeight
            self.minSize = CGSize(width: fixedWidth, height: fixedHeight)
            self.maxSize = CGSize(width: fixedWidth, height: fixedHeight)
        } else {
            self.minSize = CGSize(width: normalizedMinWidth, height: normalizedMinHeight)
            self.maxSize = CGSize(width: normalizedMaxWidth, height: normalizedMaxHeight)
        }

        self.isFixed = isFixed
    }

    static let unconstrained = WindowSizeConstraints(
        minSize: CGSize(width: 1, height: 1),
        maxSize: .zero,
        isFixed: false
    )

    static func fixed(size: CGSize) -> WindowSizeConstraints {
        WindowSizeConstraints(
            minSize: size,
            maxSize: size,
            isFixed: true
        )
    }

    func normalized() -> WindowSizeConstraints {
        WindowSizeConstraints(minSize: minSize, maxSize: maxSize, isFixed: isFixed)
    }

    var hasMinWidth: Bool {
        minSize.width > 1
    }

    var hasMinHeight: Bool {
        minSize.height > 1
    }

    var hasMaxWidth: Bool {
        maxSize.width > 0
    }

    var hasMaxHeight: Bool {
        maxSize.height > 0
    }

    func clampHeight(_ height: CGFloat) -> CGFloat {
        var result = height
        if hasMinHeight {
            result = max(result, minSize.height)
        }
        if hasMaxHeight {
            result = min(result, maxSize.height)
        }
        return result
    }

    func clampWidth(_ width: CGFloat) -> CGFloat {
        var result = width
        if hasMinWidth {
            result = max(result, minSize.width)
        }
        if hasMaxWidth {
            result = min(result, maxSize.width)
        }
        return result
    }

    private static func normalizedMinDimension(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1 }
        return max(1, value)
    }

    private static func normalizedMaxDimension(_ value: CGFloat, minimum: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return 0 }
        return max(value, minimum)
    }
}

struct PresetSize: Equatable {
    enum Kind: Equatable {
        case proportion(CGFloat)
        case fixed(CGFloat)

        var value: CGFloat {
            switch self {
            case let .proportion(proportion): proportion
            case let .fixed(size): size
            }
        }
    }

    let kind: Kind

    static func proportion(_ value: CGFloat) -> PresetSize {
        PresetSize(kind: .proportion(value))
    }

    static func fixed(_ value: CGFloat) -> PresetSize {
        PresetSize(kind: .fixed(value))
    }

    var asProportionalSize: ProportionalSize {
        switch kind {
        case let .proportion(proportion): .proportion(proportion)
        case let .fixed(size): .fixed(size)
        }
    }
}
