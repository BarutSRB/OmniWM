import Foundation

enum MonitorDescription: Equatable {
    case sequenceNumber(Int)
    case main
    case secondary
    case pattern(String)

    func resolveMonitor(sortedMonitors: [Monitor]) -> Monitor? {
        switch self {
        case let .sequenceNumber(number):
            let index = number - 1
            guard sortedMonitors.indices.contains(index) else { return nil }
            return sortedMonitors[index]
        case .main:
            return sortedMonitors.first(where: { $0.isMain }) ?? sortedMonitors.first
        case .secondary:
            guard sortedMonitors.count >= 2 else { return nil }
            if let secondary = sortedMonitors.first(where: { !$0.isMain }) {
                return secondary
            }
            return sortedMonitors.dropFirst().first
        case let .pattern(pattern):
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return nil
            }
            return sortedMonitors.first { monitor in
                let range = NSRange(monitor.name.startIndex ..< monitor.name.endIndex, in: monitor.name)
                return regex.firstMatch(in: monitor.name, options: [], range: range) != nil
            }
        }
    }
}

func parseMonitorDescription(_ raw: String) -> Result<MonitorDescription, ParseError> {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

    if let number = Int(trimmed) {
        if number >= 1 {
            return .success(.sequenceNumber(number))
        }
        return .failure(ParseError("Monitor sequence numbers use 1-based indexing"))
    }
    let normalized = trimmed.lowercased()
    if normalized == "main" {
        return .success(.main)
    }
    if normalized == "secondary" {
        return .success(.secondary)
    }
    if trimmed.isEmpty {
        return .failure(ParseError("Empty string is an illegal monitor description"))
    }

    if (try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive])) == nil {
        return .failure(ParseError("Can't parse '\(trimmed)' regex"))
    }
    return .success(.pattern(trimmed))
}
