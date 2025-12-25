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
            guard sortedMonitors.count == 2 else { return nil }
            return sortedMonitors.first(where: { !$0.isMain })
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
    if let number = Int(raw) {
        if number >= 1 {
            return .success(.sequenceNumber(number))
        }
        return .failure(ParseError("Monitor sequence numbers use 1-based indexing"))
    }
    if raw == "main" {
        return .success(.main)
    }
    if raw == "secondary" {
        return .success(.secondary)
    }
    if raw.isEmpty {
        return .failure(ParseError("Empty string is an illegal monitor description"))
    }

    if (try? NSRegularExpression(pattern: raw, options: [.caseInsensitive])) == nil {
        return .failure(ParseError("Can't parse '\(raw)' regex"))
    }
    return .success(.pattern(raw))
}
