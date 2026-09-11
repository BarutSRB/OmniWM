// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ClipboardHistoryStoreTests: XCTestCase {
    func testSupersededSaveOnlyPersistsReplacement() async throws {
        let sleeper = ClipboardSaveSleeper()
        let (store, fileURL) = try makeStore(sleeper: sleeper)
        var requests = sleeper.requests.makeAsyncIterator()

        _ = await store.handleCapture(capture("first"))
        let firstDuration = await requests.next()
        XCTAssertEqual(firstDuration, .milliseconds(250))
        let firstTask = await store.saveTask
        let obsoleteSave = try XCTUnwrap(firstTask)

        _ = await store.handleCapture(capture("second"))
        let secondDuration = await requests.next()
        XCTAssertEqual(secondDuration, .milliseconds(250))
        let secondTask = await store.saveTask
        let replacementSave = try XCTUnwrap(secondTask)

        XCTAssertTrue(obsoleteSave.isCancelled)
        await sleeper.resumeNext(throwing: CancellationError())
        await obsoleteSave.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(replacementSave.isCancelled)

        await sleeper.resumeNext()
        await replacementSave.value
        XCTAssertEqual(try persistedTitles(at: fileURL), ["second", "first"])
        let pendingSave = await store.saveTask
        XCTAssertNil(pendingSave)
    }

    func testCancelledSuccessfulSleepDoesNotFlushOrCancelReplacement() async throws {
        let sleeper = ClipboardSaveSleeper()
        let (store, fileURL) = try makeStore(sleeper: sleeper)
        var requests = sleeper.requests.makeAsyncIterator()

        _ = await store.handleCapture(capture("first"))
        _ = await requests.next()
        let firstTask = await store.saveTask
        let obsoleteSave = try XCTUnwrap(firstTask)

        _ = await store.handleCapture(capture("second"))
        _ = await requests.next()
        let secondTask = await store.saveTask
        let replacementSave = try XCTUnwrap(secondTask)

        XCTAssertTrue(obsoleteSave.isCancelled)
        await sleeper.resumeNext()
        await obsoleteSave.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(replacementSave.isCancelled)

        await sleeper.resumeNext()
        await replacementSave.value
        XCTAssertEqual(try persistedTitles(at: fileURL), ["second", "first"])
    }

    func testExplicitFlushCancelsPendingSaveWithoutLaterWrite() async throws {
        let sleeper = ClipboardSaveSleeper()
        let (store, fileURL) = try makeStore(sleeper: sleeper)
        var requests = sleeper.requests.makeAsyncIterator()

        _ = await store.handleCapture(capture("first"))
        _ = await requests.next()
        let task = await store.saveTask
        let pendingSave = try XCTUnwrap(task)

        await store.flush()
        XCTAssertTrue(pendingSave.isCancelled)
        XCTAssertEqual(try persistedTitles(at: fileURL), ["first"])
        try FileManager.default.removeItem(at: fileURL)

        await sleeper.resumeNext()
        await pendingSave.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let remainingSave = await store.saveTask
        XCTAssertNil(remainingSave)
    }

    private func makeStore(sleeper: ClipboardSaveSleeper) throws -> (ClipboardHistoryStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        let configuration = ClipboardHistoryConfiguration(
            isEnabled: true,
            maxItems: 10,
            maxItemBytes: 4096,
            maxTotalBytes: 40960,
            storageDirectory: directory
        )
        let store = ClipboardHistoryStore(configuration: configuration, sleep: { try await sleeper.sleep(for: $0) })
        return (store, configuration.storageURL)
    }

    private func capture(_ text: String) -> ClipboardPasteboardCapture {
        ClipboardPasteboardCapture(
            contents: [
                ClipboardHistoryContent(
                    itemIndex: 0,
                    type: "public.utf8-plain-text",
                    kind: .text,
                    data: Data(text.utf8)
                )
            ],
            sourceBundleIdentifier: nil,
            capturedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func persistedTitles(at fileURL: URL) throws -> [String] {
        try JSONDecoder().decode([ClipboardHistoryItem].self, from: Data(contentsOf: fileURL)).map(\.title)
    }
}

private actor ClipboardSaveSleeper {
    let requests: AsyncStream<Duration>
    private let requestContinuation: AsyncStream<Duration>.Continuation
    private var sleepers: [CheckedContinuation<Void, any Error>] = []

    init() {
        (requests, requestContinuation) = AsyncStream.makeStream()
    }

    func sleep(for duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            sleepers.append(continuation)
            requestContinuation.yield(duration)
        }
    }

    func resumeNext(throwing error: (any Error)? = nil) {
        let continuation = sleepers.removeFirst()
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}
