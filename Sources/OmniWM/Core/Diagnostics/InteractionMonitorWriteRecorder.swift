// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

final class InteractionMonitorWriteRecorder: @unchecked Sendable {
    static let shared = InteractionMonitorWriteRecorder()

    enum Field: String, Sendable {
        case interaction
        case previous
    }

    struct Entry: Sendable {
        let timestamp: Date
        let field: Field
        let oldValue: Monitor.ID?
        let newValue: Monitor.ID?
        let reason: String
    }

    private static let limit = 256

    private let buffer = LockedRingBuffer<Entry>(capacity: InteractionMonitorWriteRecorder.limit)

    func record(field: Field, oldValue: Monitor.ID?, newValue: Monitor.ID?, reason: String) {
        buffer.append(Entry(timestamp: Date(), field: field, oldValue: oldValue, newValue: newValue, reason: reason))
    }

    func dump() -> String {
        let entries = buffer.snapshot()
        guard !entries.isEmpty else { return "none" }
        return entries
            .map { entry in
                "\(entry.timestamp.ISO8601Format()) \(entry.field.rawValue) "
                    + "\(Self.format(entry.oldValue))->\(Self.format(entry.newValue)) reason=\(entry.reason)"
            }
            .joined(separator: "\n")
    }

    func reset() {
        buffer.removeAll()
    }

    private static func format(_ id: Monitor.ID?) -> String {
        id.map { String($0.displayId) } ?? "nil"
    }
}
