// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import os

struct RingBuffer<Element> {
    let capacity: Int
    private var storage: ContiguousArray<Element?>
    private var nextIndex = 0
    private(set) var size = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = []
    }

    var isEmpty: Bool {
        size == 0
    }

    @discardableResult
    mutating func append(_ element: Element) -> Element? {
        if storage.isEmpty {
            storage = ContiguousArray(repeating: nil, count: capacity)
        }
        let evicted = storage[nextIndex]
        storage[nextIndex] = element
        nextIndex = (nextIndex + 1) % capacity
        if size < capacity {
            size += 1
        }
        return evicted
    }

    func snapshot() -> [Element] {
        guard size > 0 else { return [] }
        let start = size < capacity ? 0 : nextIndex
        var result: [Element] = []
        result.reserveCapacity(size)
        for offset in 0 ..< size {
            if let element = storage[(start + offset) % capacity] {
                result.append(element)
            }
        }
        return result
    }

    mutating func removeAll() {
        for index in storage.indices {
            storage[index] = nil
        }
        nextIndex = 0
        size = 0
    }
}

extension RingBuffer: Sendable where Element: Sendable {}

final class LockedRingBuffer<Element: Sendable>: @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<RingBuffer<Element>>

    init(capacity: Int) {
        state = OSAllocatedUnfairLock(initialState: RingBuffer(capacity: capacity))
    }

    func append(_ element: Element) {
        state.withLock { state in
            _ = state.append(element)
        }
    }

    func append(_ element: Element, while predicate: @Sendable () -> Bool) {
        state.withLock { state in
            guard predicate() else { return }
            state.append(element)
        }
    }

    func snapshot() -> [Element] {
        state.withLock { $0.snapshot() }
    }

    func removeAll() {
        state.withLock { $0.removeAll() }
    }

    func synchronize() {
        state.withLock { _ in }
    }
}
