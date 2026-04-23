// SPDX-License-Identifier: GPL-2.0-only
import Foundation

struct MoveAnimation {
    let animation: SpringAnimation
    let fromOffset: CGFloat

    func currentOffset(at time: TimeInterval) -> CGFloat {
        fromOffset * CGFloat(animation.value(at: time))
    }

    func currentVelocity(at time: TimeInterval) -> Double {
        animation.velocity(at: time)
    }

    func isComplete(at time: TimeInterval) -> Bool {
        animation.isComplete(at: time)
    }
}
