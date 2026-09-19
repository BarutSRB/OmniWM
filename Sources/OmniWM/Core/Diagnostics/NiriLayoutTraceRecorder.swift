// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

enum NiriLayoutTrace {
    enum Kind: String, Sendable {
        case insertion
        case move
        case resize
        case viewport
    }

    struct Record: Sendable {
        let timestamp: Date
        let kind: Kind
        let workspaceId: UUID?
        let detail: String
    }

    static let shared = SessionTraceRecorder<Record>(
        sectionTitle: "Niri Layout Trace",
        capacity: 1024
    ) { record in
        var line = "\(record.timestamp.ISO8601Format()) \(record.kind.rawValue)"
        if let workspaceId = record.workspaceId {
            line += " ws=\(workspaceId.uuidString)"
        }
        line += " \(record.detail)"
        return line
    }

    static func record(_ kind: Kind, workspaceId: UUID?, _ detail: @autoclosure () -> String) {
        guard shared.isActive else { return }
        shared.record(Record(timestamp: Date(), kind: kind, workspaceId: workspaceId, detail: detail()))
    }
}
