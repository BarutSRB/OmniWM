// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import Synchronization

enum RuntimeTraceLimits {
    static let captureBytes = 8 * 1024 * 1024
    static let stateReportBytes = 1024 * 1024
    static let automaticEvidenceBytes = 512 * 1024
    static let diagnosticStringBytes = 4 * 1024
    static let rulesSnapshotBytes = 512 * 1024
    static let cumulativeRulesSnapshotBytes = 1024 * 1024

    static func boundedString(_ string: String) -> String {
        boundedString(string, maxBytes: diagnosticStringBytes)
    }

    static func boundedString(_ string: String, maxBytes: Int) -> String {
        guard string.utf8.count > maxBytes else { return string }
        let utf8 = string.utf8
        var end = utf8.index(utf8.startIndex, offsetBy: maxBytes)
        while end < utf8.endIndex, utf8[end] & 0xC0 == 0x80 {
            end = utf8.index(before: end)
        }
        return String(bytes: utf8[..<end], encoding: .utf8) ?? ""
    }
}

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
    func forEachLine(_ body: (String) -> Bool)
}

extension RuntimeTraceRecording {
    func forEachLine(_ body: (String) -> Bool) {
        let output = dump()
        guard output != "none" else {
            _ = body("none")
            return
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            guard body(String(line)) else { return }
        }
    }
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
        return records.map { RuntimeTraceLimits.boundedString(formatter($0)) }.joined(separator: "\n")
    }

    func forEachLine(_ body: (String) -> Bool) {
        let records = buffer.snapshot()
        guard !records.isEmpty else {
            _ = body("none")
            return
        }
        for record in records {
            guard body(RuntimeTraceLimits.boundedString(formatter(record))) else { return }
        }
    }
}
