// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CryptoKit
import Darwin
import Foundation

struct ClipboardHistoryPersistence: Sendable {
    let fileURL: URL

    func load() -> [ClipboardHistoryItem] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([ClipboardHistoryItem].self, from: data)
        else {
            return []
        }
        return items
    }

    func save(_ items: [ClipboardHistoryItem]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, S_IRWXU)
        let data = try JSONEncoder().encode(items)
        try data.write(to: fileURL, options: .atomic)
        chmod(fileURL.path, S_IRUSR | S_IWUSR)
    }
}

actor ClipboardHistoryStore {
    private var configuration: ClipboardHistoryConfiguration
    private var persistence: ClipboardHistoryPersistence
    private var items: [ClipboardHistoryItem] = []
    private var saveTask: Task<Void, Never>?

    init(configuration: ClipboardHistoryConfiguration) {
        self.configuration = configuration
        persistence = ClipboardHistoryPersistence(fileURL: configuration.storageURL)
    }

    func updateConfiguration(_ configuration: ClipboardHistoryConfiguration) -> [ClipboardPaletteItem] {
        let fileURLChanged = self.configuration.storageURL != configuration.storageURL
        self.configuration = normalized(configuration)
        if fileURLChanged {
            persistence = ClipboardHistoryPersistence(fileURL: self.configuration.storageURL)
            items = []
        }
        prune()
        scheduleSave()
        return paletteItems()
    }

    func load() -> [ClipboardPaletteItem] {
        guard items.isEmpty else { return paletteItems() }
        items = persistence.load()
        prune()
        return paletteItems()
    }

    func handleCapture(_ capture: ClipboardPasteboardCapture) -> [ClipboardPaletteItem] {
        let configuration = normalized(configuration)
        guard !capture.contents.isEmpty else { return paletteItems() }
        let byteCount = capture.contents.reduce(0) { $0 + $1.data.count }
        guard byteCount <= configuration.maxItemBytes else { return paletteItems() }

        let digest = digest(for: capture.contents)
        let title = title(for: capture.contents)
        let kind = primaryKind(for: capture.contents)
        if let index = items.firstIndex(where: { $0.digest == digest }) {
            var existing = items.remove(at: index)
            existing.lastCopiedAt = capture.capturedAt
            existing.numberOfCopies += 1
            existing.sourceBundleIdentifier = capture.sourceBundleIdentifier ?? existing.sourceBundleIdentifier
            items.insert(existing, at: 0)
        } else {
            items.insert(
                ClipboardHistoryItem(
                    id: UUID(),
                    contents: capture.contents,
                    title: title,
                    sourceBundleIdentifier: capture.sourceBundleIdentifier,
                    firstCopiedAt: capture.capturedAt,
                    lastCopiedAt: capture.capturedAt,
                    numberOfCopies: 1,
                    digest: digest,
                    byteCount: byteCount,
                    kind: kind
                ),
                at: 0
            )
        }
        prune()
        scheduleSave()
        return paletteItems()
    }

    func itemForUse(id: UUID) -> ClipboardHistoryItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        var item = items.remove(at: index)
        item.lastCopiedAt = Date()
        item.numberOfCopies += 1
        items.insert(item, at: 0)
        scheduleSave()
        return item
    }

    func delete(id: UUID) -> [ClipboardPaletteItem] {
        items.removeAll { $0.id == id }
        scheduleSave()
        return paletteItems()
    }

    func clear() -> [ClipboardPaletteItem] {
        items.removeAll()
        scheduleSave()
        return paletteItems()
    }

    func paletteItems() -> [ClipboardPaletteItem] {
        items.map(\.paletteItem)
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        try? persistence.save(items)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            await self?.flush()
        }
    }

    private func normalized(_ configuration: ClipboardHistoryConfiguration) -> ClipboardHistoryConfiguration {
        ClipboardHistoryConfiguration(
            isEnabled: configuration.isEnabled,
            maxItems: max(1, configuration.maxItems),
            maxItemBytes: max(1, configuration.maxItemBytes),
            maxTotalBytes: max(1, configuration.maxTotalBytes),
            storageDirectory: configuration.storageDirectory
        )
    }

    private func prune() {
        configuration = normalized(configuration)
        items.removeAll { $0.byteCount > configuration.maxItemBytes }
        var total = 0
        var kept: [ClipboardHistoryItem] = []
        kept.reserveCapacity(min(items.count, configuration.maxItems))
        for item in items {
            guard kept.count < configuration.maxItems else { break }
            guard total + item.byteCount <= configuration.maxTotalBytes else { continue }
            kept.append(item)
            total += item.byteCount
        }
        items = kept
    }

    private func digest(for contents: [ClipboardHistoryContent]) -> String {
        var data = Data()
        for content in contents.sorted(by: contentSort) {
            data.append(Data(content.itemIndex.description.utf8))
            data.append(0)
            data.append(Data(content.type.utf8))
            data.append(0)
            data.append(content.data)
            data.append(0)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func contentSort(_ lhs: ClipboardHistoryContent, _ rhs: ClipboardHistoryContent) -> Bool {
        if lhs.itemIndex != rhs.itemIndex { return lhs.itemIndex < rhs.itemIndex }
        return lhs.type < rhs.type
    }

    private func primaryKind(for contents: [ClipboardHistoryContent]) -> ClipboardContentKind {
        if contents.contains(where: { $0.kind == .text }) { return .text }
        if contents.contains(where: { $0.kind == .richText }) { return .richText }
        if contents.contains(where: { $0.kind == .html }) { return .html }
        if contents.contains(where: { $0.kind == .fileURL }) { return .fileURL }
        return contents.first?.kind ?? .text
    }

    private func title(for contents: [ClipboardHistoryContent]) -> String {
        if let text = contents.first(where: { $0.kind == .text }).flatMap({ String(data: $0.data, encoding: .utf8) }) {
            let collapsed = text
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return shortened(collapsed.isEmpty ? "Empty Text" : collapsed, to: 1_000)
        }
        if let fileURL = contents.first(where: { $0.kind == .fileURL }).flatMap({
            URL(dataRepresentation: $0.data, relativeTo: nil)?.lastPathComponent
        }), !fileURL.isEmpty {
            return fileURL
        }
        switch primaryKind(for: contents) {
        case .text:
            return "Text"
        case .richText:
            return "Rich Text"
        case .html:
            return "HTML"
        case .image:
            return "Image"
        case .fileURL:
            return "File"
        }
    }

    private func shortened(_ value: String, to maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        let end = value.index(value.startIndex, offsetBy: maxLength)
        return String(value[..<end])
    }
}
