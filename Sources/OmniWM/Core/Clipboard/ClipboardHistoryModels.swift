import Foundation

enum ClipboardContentKind: String, Codable, Hashable, Sendable {
    case text
    case richText
    case html
    case image
    case fileURL
}

struct ClipboardHistoryConfiguration: Equatable, Sendable {
    var isEnabled: Bool
    var maxItems: Int
    var maxItemBytes: Int
    var maxTotalBytes: Int
    var storageDirectory: URL

    var storageURL: URL {
        storageDirectory.appendingPathComponent("clipboard-history.json", isDirectory: false)
    }
}

struct ClipboardPaletteItem: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let title: String
    let subtitle: String
    let kind: ClipboardContentKind
    let sourceBundleIdentifier: String?
    let lastCopiedAt: Date
    let numberOfCopies: Int
    let byteCount: Int
}

struct ClipboardHistoryContent: Codable, Equatable, Sendable {
    let itemIndex: Int
    let type: String
    let kind: ClipboardContentKind
    let data: Data
}

struct ClipboardHistoryItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var contents: [ClipboardHistoryContent]
    var title: String
    var sourceBundleIdentifier: String?
    var firstCopiedAt: Date
    var lastCopiedAt: Date
    var numberOfCopies: Int
    var digest: String
    var byteCount: Int
    var kind: ClipboardContentKind

    var paletteItem: ClipboardPaletteItem {
        ClipboardPaletteItem(
            id: id,
            title: title,
            subtitle: Self.subtitle(
                sourceBundleIdentifier: sourceBundleIdentifier,
                lastCopiedAt: lastCopiedAt,
                numberOfCopies: numberOfCopies,
                byteCount: byteCount
            ),
            kind: kind,
            sourceBundleIdentifier: sourceBundleIdentifier,
            lastCopiedAt: lastCopiedAt,
            numberOfCopies: numberOfCopies,
            byteCount: byteCount
        )
    }

    private static func subtitle(
        sourceBundleIdentifier: String?,
        lastCopiedAt: Date,
        numberOfCopies: Int,
        byteCount: Int
    ) -> String {
        var parts: [String] = []
        if let sourceBundleIdentifier, !sourceBundleIdentifier.isEmpty {
            parts.append(sourceBundleIdentifier)
        }
        parts.append(lastCopiedAt.formatted(date: .omitted, time: .shortened))
        if numberOfCopies > 1 {
            parts.append("\(numberOfCopies)x")
        }
        if byteCount > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))
        }
        return parts.joined(separator: " - ")
    }
}

struct ClipboardPasteboardCapture: Sendable {
    let contents: [ClipboardHistoryContent]
    let sourceBundleIdentifier: String?
    let capturedAt: Date
}

struct ClipboardPasteboardCaptureConfiguration: Sendable {
    let maxItemBytes: Int
    let sourceBundleIdentifier: String?
    let capturedAt: Date
}
