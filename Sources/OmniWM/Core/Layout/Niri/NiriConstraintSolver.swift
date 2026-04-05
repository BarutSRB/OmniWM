import Foundation

enum NiriAxisSolver {
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
            return solveTabbed(windows: windows, availableSpace: availableSpace)
        }

        let totalGaps = gapSize * CGFloat(max(0, windows.count - 1))
        let usableSpace = max(0, availableSpace - totalGaps)
        let epsilon: CGFloat = 0.001

        let minConstraints = windows.map { sanitizedMinimum($0.minConstraint) }
        let maxConstraints = windows.map { window in
            sanitizedMaximum(window.hasMaxConstraint ? window.maxConstraint : nil)
        }
        let weights = windows.map { sanitizedNonNegative($0.weight) }

        let fixedValues: [CGFloat?] = windows.enumerated().map { index, window in
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

        let fixedSum = fixedValues.compactMap(\.self).reduce(0, +)
        if fixedSum > usableSpace, fixedSum > epsilon {
            let scale = usableSpace / fixedSum
            return fixedValues.map { fixedValue in
                Output(
                    value: fixedValue.map { max(1, $0 * scale) } ?? 0,
                    wasConstrained: fixedValue != nil
                )
            }
        }

        var scaledMinimums = minConstraints
        let nonFixedIndices = windows.indices.filter { fixedValues[$0] == nil }
        let remainingForMinimums = max(0, usableSpace - fixedSum)
        let minimumSum = nonFixedIndices.reduce(CGFloat.zero) { partialResult, index in
            partialResult + scaledMinimums[index]
        }

        if minimumSum > remainingForMinimums, minimumSum > epsilon {
            let scale = remainingForMinimums / minimumSum
            for index in nonFixedIndices {
                scaledMinimums[index] *= scale
            }
        }

        var values = [CGFloat](repeating: 0, count: windows.count)
        var remainingSpace = usableSpace

        for (index, fixedValue) in fixedValues.enumerated() {
            guard let fixedValue else { continue }
            let assigned = min(fixedValue, remainingSpace)
            values[index] = assigned
            remainingSpace = max(0, remainingSpace - assigned)
        }

        for index in nonFixedIndices {
            let assigned = min(scaledMinimums[index], remainingSpace)
            values[index] += assigned
            remainingSpace = max(0, remainingSpace - assigned)
        }

        while remainingSpace > epsilon {
            let growableIndices = nonFixedIndices.filter { index in
                guard let maxConstraint = maxConstraints[index] else { return true }
                return values[index] + epsilon < maxConstraint
            }

            if growableIndices.isEmpty {
                break
            }

            let totalWeight = growableIndices.reduce(CGFloat.zero) { partialResult, index in
                partialResult + weights[index]
            }

            var consumed: CGFloat = 0

            if totalWeight > epsilon {
                for index in growableIndices {
                    let share = remainingSpace * (weights[index] / totalWeight)
                    let cap = maxConstraints[index].map { max(0, $0 - values[index]) } ?? share
                    let delta = min(share, cap)
                    values[index] += delta
                    consumed += delta
                }
            } else {
                let equalShare = remainingSpace / CGFloat(growableIndices.count)
                for index in growableIndices {
                    let cap = maxConstraints[index].map { max(0, $0 - values[index]) } ?? equalShare
                    let delta = min(equalShare, cap)
                    values[index] += delta
                    consumed += delta
                }
            }

            if consumed <= epsilon {
                break
            }

            remainingSpace = max(0, remainingSpace - consumed)
        }

        return windows.enumerated().map { index, window in
            let isAtMinimum = minConstraints[index] > epsilon &&
                abs(values[index] - minConstraints[index]) <= epsilon
            let isAtMaximum = maxConstraints[index].map { abs(values[index] - $0) <= epsilon } ?? false
            return Output(
                value: max(1, values[index]),
                wasConstrained: window.isConstraintFixed || isAtMinimum || isAtMaximum
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

        sharedValue = max(1, sharedValue)

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
