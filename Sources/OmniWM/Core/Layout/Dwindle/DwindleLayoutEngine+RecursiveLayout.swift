// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension DwindleLayoutEngine {
    func calculateLayoutRecursive(
        node: DwindleNode,
        rect: CGRect,
        calculation: LayoutCalculation,
        output: inout [WindowToken: CGRect]
    ) {
        switch node.kind {
        case let .leaf(tile):
            applyLeafLayout(node: node, tile: tile, rect: rect, calculation: calculation, output: &output)

        case let .split(orientation, ratio):
            node.cachedFrame = rect

            let first = node.firstChild()
            let second = node.secondChild()
            let firstVisible = first?.projectedVisibleLeafCount ?? 0 > 0
            let secondVisible = second?.projectedVisibleLeafCount ?? 0 > 0

            if firstVisible != secondVisible {
                let visibleChild = firstVisible ? first : second
                if let visibleChild {
                    calculateLayoutRecursive(
                        node: visibleChild,
                        rect: rect,
                        calculation: calculation,
                        output: &output
                    )
                }
                return
            }
            guard firstVisible, secondVisible, let first, let second else { return }

            let firstMin = first.projectedMinSize
            let secondMin = second.projectedMinSize

            let (r1, r2) = splitRect(
                rect,
                orientation: orientation,
                ratio: ratio,
                minimums: (first: firstMin, second: secondMin),
                settings: calculation.settings
            )

            calculateLayoutRecursive(
                node: first,
                rect: r1,
                calculation: calculation,
                output: &output
            )
            calculateLayoutRecursive(
                node: second,
                rect: r2,
                calculation: calculation,
                output: &output
            )
        }
    }

    private func applyLeafLayout(
        node: DwindleNode,
        tile: DwindleTile?,
        rect: CGRect,
        calculation: LayoutCalculation,
        output: inout [WindowToken: CGRect]
    ) {
        guard let tile,
              let active = visibleMember(in: tile, excluding: calculation.excludedTokens)
        else {
            return
        }

        let target = calculation.frame(for: active, in: rect)
        node.cachedFrame = target
        let content = contentFrame(
            for: tile,
            member: active,
            tileFrame: target,
            excludedTokens: calculation.excludedTokens
        )
        node.cachedContentFrame = content
        output[active.token] = content
    }
}
