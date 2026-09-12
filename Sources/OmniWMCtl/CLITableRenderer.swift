// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import OmniWMIPC

enum CLITableRenderer {
    static func formatRows(headers: [String], rows: [[String]], format: CLIOutputFormat) -> String {
        switch format {
        case .json,
             .ndjson:
            return ""
        case .tsv:
            let sanitizedRows = ([headers] + rows).map { $0.map(sanitizedCell) }
            return sanitizedRows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        case .text,
             .table:
            return renderTable(headers: headers, rows: rows)
        }
    }

    private static func renderTable(headers: [String], rows: [[String]]) -> String {
        let cleanHeaders = headers.map(sanitizedCell)
        let cleanRows = rows.map { $0.map(sanitizedCell) }
        let widths = cleanHeaders.indices.map { column in
            ([cleanHeaders[column]] + cleanRows.map { row in row.indices.contains(column) ? row[column] : "" })
                .map(TerminalCellWidth.measure)
                .max() ?? 0
        }

        func renderRow(_ row: [String]) -> String {
            cleanHeaders.indices.map { column in
                let value = row.indices.contains(column) ? row[column] : ""
                let padding = max(0, widths[column] - TerminalCellWidth.measure(value))
                return value + String(repeating: " ", count: padding)
            }
            .joined(separator: "  ")
            .trimmingCharacters(in: .whitespaces)
        }

        var lines = [renderRow(cleanHeaders)]
        lines.append(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
        if cleanRows.isEmpty {
            lines.append("(none)")
        } else {
            lines.append(contentsOf: cleanRows.map(renderRow))
        }
        return lines.joined(separator: "\n")
    }

    private static func sanitizedCell(_ value: String) -> String {
        var result = String.UnicodeScalarView()
        result.reserveCapacity(value.unicodeScalars.count)

        for scalar in value.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control,
                 .lineSeparator,
                 .paragraphSeparator:
                result.append(" ")
            default:
                result.append(scalar)
            }
        }

        return String(result)
    }

    static func boolDescription(_ value: Bool?) -> String {
        guard let value else { return "-" }
        return value ? "yes" : "no"
    }
}
