import Foundation

enum NiriAxisSolver {
    @usableFromInline
    static let minimumRenderableSpan: CGFloat = 1

    struct Input {
        let weight: CGFloat
        let minConstraint: CGFloat
        let maxConstraint: CGFloat
        let hasMaxConstraint: Bool
        let isConstraintFixed: Bool
        let hasFixedValue: Bool
        let fixedValue: CGFloat?
    }

    struct Output {
        let value: CGFloat
        let wasConstrained: Bool
    }

    @inlinable
    static func solve(
        windows: [Input],
        availableSpace: CGFloat,
        gapSize: CGFloat,
        isTabbed: Bool = false
    ) -> [Output] {
        guard !windows.isEmpty else { return [] }

        if isTabbed {
            let usableSpace = max(0, availableSpace - gapSize * 2)
            return solveTabbed(windows: windows, availableSpace: usableSpace)
        }

        let totalGaps = gapSize * CGFloat(windows.count + 1)
        let usableSpace = max(0, availableSpace - totalGaps)
        let epsilon: CGFloat = 0.001
        let minConstraints = windows.map { sanitizedMinimum($0.minConstraint) }
        let maxConstraints = windows.map { window in
            sanitizedMaximum(window.hasMaxConstraint ? window.maxConstraint : nil)
        }
        let weights = windows.map { sanitizedNonNegative($0.weight) }

        var fixedValues: [CGFloat?] = windows.enumerated().map { index, window in
            if window.hasFixedValue, let fixedValue = window.fixedValue {
                return clampedFixedValue(
                    fixedValue,
                    minimum: minConstraints[index],
                    maximum: maxConstraints[index]
                )
            }
            if window.isConstraintFixed {
                return clampedFixedValue(
                    minConstraints[index],
                    minimum: minConstraints[index],
                    maximum: maxConstraints[index]
                )
            }
            return nil
        }

        var fixedWasScaled = [Bool](repeating: false, count: windows.count)
        var fixedSum = fixedValues.compactMap(\.self).reduce(0, +)
        let nonFixedIndices = windows.indices.filter { fixedValues[$0] == nil }
        let fixedBudget = max(
            0,
            usableSpace - nonFixedIndices.reduce(CGFloat.zero) { partialResult, index in
                partialResult + max(Self.minimumRenderableSpan, minConstraints[index])
            }
        )
        if fixedSum > fixedBudget, fixedSum > epsilon {
            // Preserve room for every auto tile's render floor, even when that scales fixed tiles below their min.
            let scale = fixedBudget / fixedSum
            for index in fixedValues.indices {
                guard let fixedValue = fixedValues[index] else { continue }
                let scaledValue = max(0, fixedValue * scale)
                fixedWasScaled[index] = abs(scaledValue - fixedValue) > epsilon
                fixedValues[index] = scaledValue
            }
            fixedSum = fixedValues.compactMap(\.self).reduce(0, +)
        }
        let remainingSpace = max(0, usableSpace - fixedSum)
        var values = [CGFloat](repeating: 0, count: windows.count)

        for (index, fixedValue) in fixedValues.enumerated() {
            guard let fixedValue else { continue }
            values[index] = fixedValue
        }

        var pinnedIndices = Set<Int>()
        var pinnedMinimumSum: CGFloat = 0
        while pinnedIndices.count < nonFixedIndices.count {
            let distributableSpace = max(0, remainingSpace - pinnedMinimumSum)
            var totalWeight: CGFloat = 0
            for index in nonFixedIndices where !pinnedIndices.contains(index) {
                totalWeight += max(weights[index], epsilon)
            }
            guard totalWeight > epsilon else { break }

            var pinnedIndex: Int?
            for index in nonFixedIndices where !pinnedIndices.contains(index) {
                let share = distributableSpace * (max(weights[index], epsilon) / totalWeight)
                if share + epsilon < minConstraints[index] {
                    pinnedIndex = index
                    break
                }
            }

            if let pinnedIndex {
                values[pinnedIndex] = minConstraints[pinnedIndex]
                pinnedMinimumSum += minConstraints[pinnedIndex]
                pinnedIndices.insert(pinnedIndex)
                continue
            }

            for index in nonFixedIndices where !pinnedIndices.contains(index) {
                values[index] = distributableSpace * (max(weights[index], epsilon) / totalWeight)
            }
            break
        }

        return windows.enumerated().map { index, window in
            let isAtMinimum = minConstraints[index] > epsilon &&
                abs(values[index] - minConstraints[index]) <= epsilon
            let isAtMaximum = fixedValues[index] != nil &&
                (maxConstraints[index].map { abs(values[index] - $0) <= epsilon } ?? false)
            return Output(
                value: max(Self.minimumRenderableSpan, values[index]),
                wasConstrained: window.isConstraintFixed || fixedWasScaled[index] || isAtMinimum || isAtMaximum
            )
        }
    }

    @inlinable
    static func solveTabbed(
        windows: [Input],
        availableSpace: CGFloat
    ) -> [Output] {
        let maxMinConstraint = windows.map(\.minConstraint).max() ?? 1
        let fixedValue = windows.first(where: { $0.hasFixedValue && $0.fixedValue != nil })?.fixedValue

        var sharedValue: CGFloat = if let fixed = fixedValue {
            max(fixed, maxMinConstraint)
        } else {
            max(availableSpace, maxMinConstraint)
        }

        let maxMaxConstraint = windows.compactMap {
            sanitizedMaximum($0.hasMaxConstraint ? $0.maxConstraint : nil)
        }
        .min()
        if let maxC = maxMaxConstraint {
            sharedValue = min(sharedValue, max(maxC, maxMinConstraint))
        }

        sharedValue = max(Self.minimumRenderableSpan, sharedValue)

        return windows.map { window in
            let wasConstrained = sharedValue == window.minConstraint ||
                (window.hasMaxConstraint && sharedValue == window.maxConstraint)
            return Output(value: sharedValue, wasConstrained: wasConstrained)
        }
    }

    @inlinable
    static func sanitizedNonNegative(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }

    @inlinable
    static func sanitizedMinimum(_ value: CGFloat) -> CGFloat {
        sanitizedNonNegative(value)
    }

    @inlinable
    static func sanitizedMaximum(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return max(0, value)
    }

    @inlinable
    static func clampedFixedValue(
        _ value: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat?
    ) -> CGFloat {
        var clamped = sanitizedNonNegative(value)
        clamped = max(clamped, minimum)
        if let maximum {
            clamped = min(clamped, maximum)
        }
        return clamped
    }
}
