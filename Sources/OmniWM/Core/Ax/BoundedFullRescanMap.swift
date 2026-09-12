// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

private struct IndexedAsyncValue<Value: Sendable>: Sendable {
    let index: Int
    let value: Value
}

func boundedFullRescanMap<Input: Sendable, Output: Sendable>(
    _ inputs: [Input],
    maxConcurrent: Int,
    priority: @Sendable @escaping (Input) -> TaskPriority? = { _ in nil },
    operation: @Sendable @escaping (Input) async throws -> Output
) async throws -> [Output] {
    guard !inputs.isEmpty else { return [] }
    precondition(maxConcurrent > 0)
    return try await withThrowingTaskGroup(of: IndexedAsyncValue<Output>.self) { group in
        var nextIndex = 0
        let initialCount = min(maxConcurrent, inputs.count)
        for index in 0 ..< initialCount {
            try Task.checkCancellation()
            let input = inputs[index]
            guard group.addTaskUnlessCancelled(priority: priority(input), operation: {
                IndexedAsyncValue(index: index, value: try await operation(input))
            }) else { throw CancellationError() }
            nextIndex += 1
        }

        var completed: [IndexedAsyncValue<Output>] = []
        completed.reserveCapacity(inputs.count)
        while let result = try await group.next() {
            completed.append(result)
            try Task.checkCancellation()
            if nextIndex < inputs.count {
                let index = nextIndex
                let input = inputs[index]
                guard group.addTaskUnlessCancelled(priority: priority(input), operation: {
                    IndexedAsyncValue(index: index, value: try await operation(input))
                }) else { throw CancellationError() }
                nextIndex += 1
            }
        }
        completed.sort { $0.index < $1.index }
        return completed.map(\.value)
    }
}
