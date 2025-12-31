import Foundation

enum NiriColumnHeightSolver {
    struct WindowInput {
        let weight: CGFloat

        let constraints: WindowSizeConstraints

        let isFixedHeight: Bool

        let fixedHeight: CGFloat?
    }

    struct WindowOutput {
        let height: CGFloat

        let wasConstrained: Bool
    }

    static func solve(
        windows: [WindowInput],
        availableHeight: CGFloat,
        gapSize: CGFloat,
        isTabbed: Bool = false
    ) -> [WindowOutput] {
        guard !windows.isEmpty else { return [] }

        if isTabbed {
            return solveTabbed(windows: windows, availableHeight: availableHeight)
        }

        let totalGaps = gapSize * CGFloat(max(0, windows.count - 1))
        let heightForWindows = availableHeight - totalGaps

        guard heightForWindows > 0 else {
            return windows.map { window in
                WindowOutput(
                    height: window.constraints.minSize.height,
                    wasConstrained: true
                )
            }
        }

        var heights = [CGFloat](repeating: 0, count: windows.count)
        var isFixed = [Bool](repeating: false, count: windows.count)
        var usedHeight: CGFloat = 0

        for (i, window) in windows.enumerated() {
            if window.isFixedHeight, let fixedH = window.fixedHeight {
                let clampedHeight = window.constraints.clampHeight(fixedH)
                heights[i] = clampedHeight
                isFixed[i] = true
                usedHeight += clampedHeight
            } else if window.constraints.isFixed {
                heights[i] = window.constraints.minSize.height
                isFixed[i] = true
                usedHeight += heights[i]
            }
        }

        let maxIterations = windows.count + 1
        var iteration = 0

        while iteration < maxIterations {
            iteration += 1

            let remainingHeight = heightForWindows - usedHeight
            var totalWeight: CGFloat = 0

            for (i, window) in windows.enumerated() {
                if !isFixed[i] {
                    totalWeight += window.weight
                }
            }

            if totalWeight <= 0 {
                break
            }

            var anyViolation = false

            for (i, window) in windows.enumerated() {
                if isFixed[i] { continue }

                let proposedHeight = remainingHeight * (window.weight / totalWeight)
                let minHeight = window.constraints.minSize.height

                if proposedHeight < minHeight {
                    heights[i] = minHeight
                    isFixed[i] = true
                    usedHeight += minHeight
                    anyViolation = true
                    break
                }
            }

            if !anyViolation {
                for (i, window) in windows.enumerated() {
                    if !isFixed[i] {
                        heights[i] = remainingHeight * (window.weight / totalWeight)
                    }
                }
                break
            }
        }

        var excessHeight: CGFloat = 0

        for (i, window) in windows.enumerated() {
            if window.constraints.hasMaxHeight, heights[i] > window.constraints.maxSize.height {
                let excess = heights[i] - window.constraints.maxSize.height
                heights[i] = window.constraints.maxSize.height
                excessHeight += excess
                isFixed[i] = true
            }
        }

        if excessHeight > 0 {
            var remainingWeight: CGFloat = 0
            for (i, window) in windows.enumerated() {
                if !isFixed[i] {
                    remainingWeight += window.weight
                }
            }

            if remainingWeight > 0 {
                for (i, window) in windows.enumerated() {
                    if !isFixed[i] {
                        heights[i] += excessHeight * (window.weight / remainingWeight)
                    }
                }
            }
        }

        var outputs: [WindowOutput] = []
        for (i, window) in windows.enumerated() {
            let wasConstrained = isFixed[i] && (
                heights[i] == window.constraints.minSize.height ||
                    heights[i] == window.constraints.maxSize.height
            )
            outputs.append(WindowOutput(
                height: max(1, heights[i]),
                wasConstrained: wasConstrained
            ))
        }

        return outputs
    }

    private static func solveTabbed(
        windows: [WindowInput],
        availableHeight: CGFloat
    ) -> [WindowOutput] {
        let maxMinHeight = windows.map(\.constraints.minSize.height).max() ?? 1

        let fixedHeight = windows.first(where: { $0.isFixedHeight && $0.fixedHeight != nil })?.fixedHeight

        var sharedHeight: CGFloat = if let fixed = fixedHeight {
            max(fixed, maxMinHeight)
        } else {
            max(availableHeight, maxMinHeight)
        }

        let maxMaxHeight = windows.compactMap { $0.constraints.hasMaxHeight ? $0.constraints.maxSize.height : nil }
            .min()
        if let maxH = maxMaxHeight {
            sharedHeight = min(sharedHeight, maxH)
        }

        sharedHeight = max(1, sharedHeight)

        return windows.map { window in
            let wasConstrained = sharedHeight == window.constraints.minSize.height ||
                (window.constraints.hasMaxHeight && sharedHeight == window.constraints.maxSize.height)
            return WindowOutput(height: sharedHeight, wasConstrained: wasConstrained)
        }
    }
}

enum NiriRowWidthSolver {
    struct WindowInput {
        let weight: CGFloat

        let constraints: WindowSizeConstraints

        let isFixedWidth: Bool

        let fixedWidth: CGFloat?
    }

    struct WindowOutput {
        let width: CGFloat

        let wasConstrained: Bool
    }

    static func solve(
        windows: [WindowInput],
        availableWidth: CGFloat,
        gapSize: CGFloat,
        isTabbed: Bool = false
    ) -> [WindowOutput] {
        guard !windows.isEmpty else { return [] }

        if isTabbed {
            return solveTabbed(windows: windows, availableWidth: availableWidth)
        }

        let totalGaps = gapSize * CGFloat(max(0, windows.count - 1))
        let widthForWindows = availableWidth - totalGaps

        guard widthForWindows > 0 else {
            return windows.map { window in
                WindowOutput(
                    width: window.constraints.minSize.width,
                    wasConstrained: true
                )
            }
        }

        var widths = [CGFloat](repeating: 0, count: windows.count)
        var isFixed = [Bool](repeating: false, count: windows.count)
        var usedWidth: CGFloat = 0

        for (i, window) in windows.enumerated() {
            if window.isFixedWidth, let fixedW = window.fixedWidth {
                let clampedWidth = window.constraints.clampWidth(fixedW)
                widths[i] = clampedWidth
                isFixed[i] = true
                usedWidth += clampedWidth
            } else if window.constraints.isFixed {
                widths[i] = window.constraints.minSize.width
                isFixed[i] = true
                usedWidth += widths[i]
            }
        }

        let maxIterations = windows.count + 1
        var iteration = 0

        while iteration < maxIterations {
            iteration += 1

            let remainingWidth = widthForWindows - usedWidth
            var totalWeight: CGFloat = 0

            for (i, window) in windows.enumerated() {
                if !isFixed[i] {
                    totalWeight += window.weight
                }
            }

            if totalWeight <= 0 {
                break
            }

            var anyViolation = false

            for (i, window) in windows.enumerated() {
                if isFixed[i] { continue }

                let proposedWidth = remainingWidth * (window.weight / totalWeight)
                let minWidth = window.constraints.minSize.width

                if proposedWidth < minWidth {
                    widths[i] = minWidth
                    isFixed[i] = true
                    usedWidth += minWidth
                    anyViolation = true
                    break
                }
            }

            if !anyViolation {
                for (i, window) in windows.enumerated() {
                    if !isFixed[i] {
                        widths[i] = remainingWidth * (window.weight / totalWeight)
                    }
                }
                break
            }
        }

        var excessWidth: CGFloat = 0

        for (i, window) in windows.enumerated() {
            if window.constraints.hasMaxWidth, widths[i] > window.constraints.maxSize.width {
                let excess = widths[i] - window.constraints.maxSize.width
                widths[i] = window.constraints.maxSize.width
                excessWidth += excess
                isFixed[i] = true
            }
        }

        if excessWidth > 0 {
            var remainingWeight: CGFloat = 0
            for (i, window) in windows.enumerated() {
                if !isFixed[i] {
                    remainingWeight += window.weight
                }
            }

            if remainingWeight > 0 {
                for (i, window) in windows.enumerated() {
                    if !isFixed[i] {
                        widths[i] += excessWidth * (window.weight / remainingWeight)
                    }
                }
            }
        }

        var outputs: [WindowOutput] = []
        for (i, window) in windows.enumerated() {
            let wasConstrained = isFixed[i] && (
                widths[i] == window.constraints.minSize.width ||
                    widths[i] == window.constraints.maxSize.width
            )
            outputs.append(WindowOutput(
                width: max(1, widths[i]),
                wasConstrained: wasConstrained
            ))
        }

        return outputs
    }

    private static func solveTabbed(
        windows: [WindowInput],
        availableWidth: CGFloat
    ) -> [WindowOutput] {
        let maxMinWidth = windows.map(\.constraints.minSize.width).max() ?? 1

        let fixedWidth = windows.first(where: { $0.isFixedWidth && $0.fixedWidth != nil })?.fixedWidth

        var sharedWidth: CGFloat = if let fixed = fixedWidth {
            max(fixed, maxMinWidth)
        } else {
            max(availableWidth, maxMinWidth)
        }

        let maxMaxWidth = windows.compactMap { $0.constraints.hasMaxWidth ? $0.constraints.maxSize.width : nil }
            .min()
        if let maxW = maxMaxWidth {
            sharedWidth = min(sharedWidth, maxW)
        }

        sharedWidth = max(1, sharedWidth)

        return windows.map { window in
            let wasConstrained = sharedWidth == window.constraints.minSize.width ||
                (window.constraints.hasMaxWidth && sharedWidth == window.constraints.maxSize.width)
            return WindowOutput(width: sharedWidth, wasConstrained: wasConstrained)
        }
    }
}

enum NiriColumnWidthSolver {
    struct ColumnInput {
        let width: ColumnWidth

        let isFullWidth: Bool

        let minWidth: CGFloat?
        let maxWidth: CGFloat?
    }

    struct ColumnOutput {
        let width: CGFloat

        let wasConstrained: Bool
    }

    static func solve(
        columns: [ColumnInput],
        availableWidth: CGFloat,
        gapSize: CGFloat
    ) -> [ColumnOutput] {
        guard !columns.isEmpty else { return [] }

        let totalGaps = gapSize * CGFloat(max(0, columns.count - 1))
        let widthForColumns = availableWidth - totalGaps

        guard widthForColumns > 0 else {
            return columns.map { _ in
                ColumnOutput(width: 0, wasConstrained: true)
            }
        }

        for (i, column) in columns.enumerated() {
            if column.isFullWidth {
                return columns.enumerated().map { j, _ in
                    ColumnOutput(
                        width: j == i ? widthForColumns : 0,
                        wasConstrained: false
                    )
                }
            }
        }

        var totalWeight: CGFloat = 0
        var widths = [CGFloat](repeating: 0, count: columns.count)
        var isFixed = [Bool](repeating: false, count: columns.count)
        var wasConstrained = [Bool](repeating: false, count: columns.count)

        for (i, column) in columns.enumerated() {
            switch column.width {
            case let .proportion(p):
                totalWeight += p
            case let .fixed(f):
                let minW = column.minWidth ?? 0
                let maxW = column.maxWidth ?? f
                let clamped = f.clamped(to: minW ... maxW)
                widths[i] = min(clamped, widthForColumns)
                isFixed[i] = true
                wasConstrained[i] = clamped != f
            }
        }

        let maxIterations = columns.count + 2
        var iteration = 0

        while iteration < maxIterations {
            iteration += 1

            let usedWidth = widths.enumerated().reduce(CGFloat(0)) { acc, pair in
                let (idx, value) = pair
                return isFixed[idx] ? acc + value : acc
            }

            let remainingWidth = widthForColumns - usedWidth
            var remainingWeight: CGFloat = 0
            for (i, column) in columns.enumerated() where !isFixed[i] {
                if case let .proportion(p) = column.width {
                    remainingWeight += p
                }
            }

            guard remainingWidth > 0, remainingWeight > 0 else {
                break
            }

            var lockedThisPass = false

            for (i, column) in columns.enumerated() where !isFixed[i] {
                guard case let .proportion(p) = column.width else { continue }

                let proposed = remainingWidth * (p / remainingWeight)
                let minW = column.minWidth ?? 0
                let maxW = column.maxWidth ?? .greatestFiniteMagnitude

                if proposed < minW {
                    widths[i] = minW
                    isFixed[i] = true
                    wasConstrained[i] = true
                    lockedThisPass = true
                    break
                } else if proposed > maxW {
                    widths[i] = maxW
                    isFixed[i] = true
                    wasConstrained[i] = true
                    lockedThisPass = true
                    break
                } else {
                    widths[i] = proposed
                }
            }

            if !lockedThisPass {
                break
            }
        }

        return columns.enumerated().map { i, _ in
            ColumnOutput(
                width: max(1, widths[i]),
                wasConstrained: wasConstrained[i]
            )
        }
    }
}
