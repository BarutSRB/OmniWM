import AppKit
import Foundation
@testable import OmniWM
import Testing

private final class ClipboardHistoryTestWriteProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ClipboardHistoryItem] = []

    func append(_ item: ClipboardHistoryItem) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    func snapshot() -> [ClipboardHistoryItem] {
        lock.lock()
        let snapshot = items
        lock.unlock()
        return snapshot
    }
}

private final class ClipboardHistoryChangeCountProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int

    init(_ value: Int) {
        self.value = value
    }

    func get() -> Int {
        lock.lock()
        let value = value
        lock.unlock()
        return value
    }

    func set(_ value: Int) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

@MainActor
private final class ClipboardHistoryTestTimer: ClipboardHistoryTimer {
    let interval: TimeInterval
    private let action: @MainActor () -> Void
    private(set) var isInvalidated = false

    init(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.action = action
    }

    func invalidate() {
        isInvalidated = true
    }

    func fire() {
        guard !isInvalidated else { return }
        action()
    }
}

private func makeClipboardHistoryTestDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("omniwm-clipboard-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func makeClipboardHistoryTestConfiguration(
    isEnabled: Bool = true,
    maxItems: Int = 200,
    maxItemBytes: Int = 8_388_608,
    maxTotalBytes: Int = 67_108_864,
    directory: URL = makeClipboardHistoryTestDirectory()
) -> ClipboardHistoryConfiguration {
    ClipboardHistoryConfiguration(
        isEnabled: isEnabled,
        maxItems: maxItems,
        maxItemBytes: maxItemBytes,
        maxTotalBytes: maxTotalBytes,
        storageDirectory: directory
    )
}

private func makeClipboardTextContent(
    _ value: String,
    itemIndex: Int = 0
) -> ClipboardHistoryContent {
    ClipboardHistoryContent(
        itemIndex: itemIndex,
        type: NSPasteboard.PasteboardType.string.rawValue,
        kind: .text,
        data: Data(value.utf8)
    )
}

private func makeClipboardFileURLContent(
    _ url: URL,
    itemIndex: Int = 0
) -> ClipboardHistoryContent {
    ClipboardHistoryContent(
        itemIndex: itemIndex,
        type: NSPasteboard.PasteboardType.fileURL.rawValue,
        kind: .fileURL,
        data: url.dataRepresentation
    )
}

private func makeClipboardCapture(
    contents: [ClipboardHistoryContent],
    sourceBundleIdentifier: String? = "com.example.source",
    capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> ClipboardPasteboardCapture {
    ClipboardPasteboardCapture(
        contents: contents,
        sourceBundleIdentifier: sourceBundleIdentifier,
        capturedAt: capturedAt
    )
}

private func makePasteboardCaptureConfiguration(maxItemBytes: Int = 8_388_608) -> ClipboardPasteboardCaptureConfiguration {
    ClipboardPasteboardCaptureConfiguration(
        maxItemBytes: maxItemBytes,
        sourceBundleIdentifier: "com.example.frontmost",
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

@MainActor
private func waitForClipboardTitles(
    _ expected: [String],
    in service: ClipboardHistoryService,
    timeout: Duration = .seconds(1)
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if service.paletteItems.map(\.title) == expected {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return service.paletteItems.map(\.title) == expected
}

@Suite(.serialized) @MainActor struct ClipboardHistoryServiceTests {
    @Test func pasteboardCaptureRejectsPrivateAndSelfWrittenTypes() throws {
        let concealed = NSPasteboardItem()
        concealed.setString("secret", forType: .string)
        concealed.setString("1", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))

        let selfWritten = NSPasteboardItem()
        selfWritten.setString("from OmniWM", forType: .string)
        selfWritten.setString("1", forType: ClipboardHistoryPasteboard.markerType)

        let unsupported = NSPasteboardItem()
        unsupported.setString("ignored", forType: NSPasteboard.PasteboardType("com.example.unsupported"))

        let withSourceMarker = NSPasteboardItem()
        withSourceMarker.setString("visible", forType: .string)
        withSourceMarker.setString("com.example.source", forType: ClipboardHistoryPasteboard.sourceType)

        let configuration = makePasteboardCaptureConfiguration()

        #expect(ClipboardHistoryPasteboard.capture(pasteboardItems: [concealed], configuration: configuration) == nil)
        #expect(ClipboardHistoryPasteboard.capture(pasteboardItems: [selfWritten], configuration: configuration) == nil)
        #expect(ClipboardHistoryPasteboard.capture(pasteboardItems: [unsupported], configuration: configuration) == nil)

        let captured = try #require(
            ClipboardHistoryPasteboard.capture(pasteboardItems: [withSourceMarker], configuration: configuration)
        )
        #expect(captured.contents.count == 1)
        #expect(captured.contents.first?.kind == .text)
        #expect(captured.sourceBundleIdentifier == "com.example.frontmost")
    }

    @Test func pasteboardCaptureAllowsCommonTypesAndFallsBackToTextWithinByteCap() throws {
        let item = NSPasteboardItem()
        item.setString("ok", forType: .string)
        item.setData(Data(repeating: 7, count: 16), forType: .png)

        let textOnly = try #require(
            ClipboardHistoryPasteboard.capture(
                pasteboardItems: [item],
                configuration: makePasteboardCaptureConfiguration(maxItemBytes: 4)
            )
        )
        #expect(textOnly.contents.map(\.kind) == [.text])

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("Clipboard Test.txt")
        let fileItem = NSPasteboardItem()
        fileItem.setData(fileURL.dataRepresentation, forType: .fileURL)

        let fileCapture = try #require(
            ClipboardHistoryPasteboard.capture(
                pasteboardItems: [fileItem],
                configuration: makePasteboardCaptureConfiguration()
            )
        )
        #expect(fileCapture.contents.map(\.kind) == [.fileURL])
    }

    @Test func serviceDedupesPrunesAndPersistsWithPrivatePermissions() async throws {
        let directory = makeClipboardHistoryTestDirectory()
        let configuration = makeClipboardHistoryTestConfiguration(
            maxItems: 3,
            maxItemBytes: 32,
            maxTotalBytes: 128,
            directory: directory
        )
        let service = ClipboardHistoryService(configuration: configuration)

        _ = await service.handleCaptureForTests(makeClipboardCapture(contents: [makeClipboardTextContent("Alpha")]))
        _ = await service.handleCaptureForTests(makeClipboardCapture(contents: [makeClipboardTextContent("Beta")]))
        let deduped = await service.handleCaptureForTests(makeClipboardCapture(contents: [makeClipboardTextContent("Alpha")]))

        #expect(deduped.map(\.title) == ["Alpha", "Beta"])
        #expect(deduped.first?.numberOfCopies == 2)

        await service.flushAndStop()

        let fileURL = configuration.storageURL
        let persistedData = try Data(contentsOf: fileURL)
        let persistedItems = try JSONDecoder().decode([ClipboardHistoryItem].self, from: persistedData)
        #expect(persistedItems.map(\.title) == ["Alpha", "Beta"])

        let directoryMode = try #require(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        ).intValue
        let fileMode = try #require(
            FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
        ).intValue
        #expect(directoryMode & 0o777 == 0o700)
        #expect(fileMode & 0o777 == 0o600)
    }

    @Test func serviceEnforcesItemAndTotalByteCaps() async {
        let configuration = makeClipboardHistoryTestConfiguration(
            maxItems: 10,
            maxItemBytes: 5,
            maxTotalBytes: 9
        )
        let service = ClipboardHistoryService(configuration: configuration)

        let rejected = await service.handleCaptureForTests(
            makeClipboardCapture(contents: [makeClipboardTextContent("toolong")])
        )
        #expect(rejected.isEmpty)

        _ = await service.handleCaptureForTests(makeClipboardCapture(contents: [makeClipboardTextContent("12345")]))
        let pruned = await service.handleCaptureForTests(makeClipboardCapture(contents: [makeClipboardTextContent("67890")]))

        #expect(pruned.map(\.title) == ["67890"])
    }

    @Test func storeLoadDoesNotClobberNewerInMemoryCaptures() async {
        let configuration = makeClipboardHistoryTestConfiguration()
        let store = ClipboardHistoryStore(configuration: configuration)

        _ = await store.handleCapture(makeClipboardCapture(contents: [makeClipboardTextContent("Fresh")]))
        let loaded = await store.load()

        #expect(loaded.map(\.title) == ["Fresh"])
    }

    @Test func copyDeleteAndClearUseStoredPayloads() async throws {
        let writeProbe = ClipboardHistoryTestWriteProbe()
        let directory = makeClipboardHistoryTestDirectory()
        var environment = ClipboardHistoryServiceEnvironment()
        environment.writePasteboard = { item in
            writeProbe.append(item)
            return true
        }
        let configuration = makeClipboardHistoryTestConfiguration(directory: directory)
        let service = ClipboardHistoryService(configuration: configuration, environment: environment)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("Clipboard Payload.txt")
        let snapshots = await service.handleCaptureForTests(makeClipboardCapture(contents: [
            makeClipboardTextContent("Payload"),
            makeClipboardFileURLContent(fileURL, itemIndex: 1)
        ]))
        let itemID = try #require(snapshots.first?.id)

        #expect(await service.copyItemToPasteboard(id: itemID))
        let written = try #require(writeProbe.snapshot().first)
        #expect(written.contents.map(\.kind) == [.text, .fileURL])

        let afterDelete = await service.deleteItem(id: itemID)
        #expect(afterDelete.isEmpty)

        _ = await service.handleCaptureForTests(makeClipboardCapture(contents: [makeClipboardTextContent("Again")]))
        let afterClear = await service.clearHistory()
        #expect(afterClear.isEmpty)
    }

    @Test func pollingReadsOnlyWhenChangeCountMoves() async throws {
        let changeCount = ClipboardHistoryChangeCountProbe(10)
        var timer: ClipboardHistoryTestTimer?
        let directory = makeClipboardHistoryTestDirectory()
        var environment = ClipboardHistoryServiceEnvironment()
        environment.pasteboardChangeCount = { changeCount.get() }
        environment.frontmostBundleIdentifier = { "com.example.frontmost" }
        environment.capturePasteboard = { configuration in
            makeClipboardCapture(
                contents: [makeClipboardTextContent("Polled")],
                sourceBundleIdentifier: configuration.sourceBundleIdentifier,
                capturedAt: configuration.capturedAt
            )
        }
        environment.makeTimer = { interval, action in
            let newTimer = ClipboardHistoryTestTimer(interval: interval, action: action)
            timer = newTimer
            return newTimer
        }
        let service = ClipboardHistoryService(
            configuration: makeClipboardHistoryTestConfiguration(directory: directory),
            environment: environment
        )

        service.start()
        let installedTimer = try #require(timer)
        #expect(installedTimer.interval == 0.5)

        installedTimer.fire()
        #expect(await waitForClipboardTitles(["Polled"], in: service, timeout: .milliseconds(100)) == false)

        changeCount.set(11)
        installedTimer.fire()
        #expect(await waitForClipboardTitles(["Polled"], in: service))

        await service.flushAndStop()
        #expect(installedTimer.isInvalidated)
    }
}
