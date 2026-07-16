// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import Synchronization

enum TraceFormat {
    static func rect(_ rect: CGRect?) -> String {
        guard let rect else { return "nil" }
        return String(
            format: "(%.0f,%.0f %.0fx%.0f)",
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height
        )
    }

    static func point(_ point: CGPoint?) -> String {
        guard let point else { return "nil" }
        return String(format: "(%.0f,%.0f)", point.x, point.y)
    }
}

protocol RuntimeTraceRecording: Sendable {
    var sectionTitle: String { get }
    func beginCapture()
    func endCapture()
    func dump() -> String
}

final class SessionTraceRecorder<Record: Sendable>: RuntimeTraceRecording, @unchecked Sendable {
    let sectionTitle: String

    private let buffer: LockedRingBuffer<Record>
    private let active = Atomic<Bool>(false)
    private let formatter: @Sendable (Record) -> String

    init(sectionTitle: String, capacity: Int, formatter: @escaping @Sendable (Record) -> String) {
        self.sectionTitle = sectionTitle
        buffer = LockedRingBuffer(capacity: capacity)
        self.formatter = formatter
    }

    var isActive: Bool {
        active.load(ordering: .relaxed)
    }

    func record(_ make: @autoclosure () -> Record) {
        guard active.load(ordering: .relaxed) else { return }
        buffer.append(make(), while: {
            active.load(ordering: .relaxed)
        })
    }

    func beginCapture() {
        buffer.removeAll()
        active.store(true, ordering: .relaxed)
    }

    func endCapture() {
        active.store(false, ordering: .relaxed)
        buffer.synchronize()
    }

    func dump() -> String {
        let records = buffer.snapshot()
        guard !records.isEmpty else { return "none" }
        return records.map(formatter).joined(separator: "\n")
    }
}
