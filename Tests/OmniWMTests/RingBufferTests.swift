// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class RingBufferTests: XCTestCase {
    func testAppendWithinCapacityPreservesOrder() {
        var ring = RingBuffer<Int>(capacity: 3)
        ring.append(1)
        ring.append(2)
        XCTAssertEqual(ring.snapshot(), [1, 2])
        XCTAssertEqual(ring.size, 2)
        XCTAssertFalse(ring.isEmpty)
    }

    func testEvictsOldestBeyondCapacity() {
        var ring = RingBuffer<Int>(capacity: 3)
        for value in 1 ... 5 {
            ring.append(value)
        }
        XCTAssertEqual(ring.snapshot(), [3, 4, 5])
        XCTAssertEqual(ring.size, 3)
    }

    func testRemoveAllResets() {
        var ring = RingBuffer<Int>(capacity: 3)
        ring.append(1)
        ring.append(2)
        ring.removeAll()
        XCTAssertTrue(ring.isEmpty)
        XCTAssertEqual(ring.snapshot(), [])
        ring.append(9)
        XCTAssertEqual(ring.snapshot(), [9])
    }

    func testCapacityClampedToAtLeastOne() {
        var ring = RingBuffer<Int>(capacity: 0)
        ring.append(1)
        ring.append(2)
        XCTAssertEqual(ring.snapshot(), [2])
    }
}
