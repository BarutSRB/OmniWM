// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
final class RuntimeStateStoreTests: XCTestCase {
    func testDeferredSavesCoalesceAndWriteOffMainThread() async throws {
        let directory = makeDirectory()
        let calls = Mutex<[(String?, Bool)]>([])
        let store = RuntimeStateStore(directory: directory) { state, url in
            calls.withLock { $0.append((state.updaterSkippedReleaseTag, Thread.isMainThread)) }
            try RuntimeStateStore.writeState(state, to: url)
        }
        store.updaterSkippedReleaseTag = "first"
        store.updaterSkippedReleaseTag = "second"
        store.updaterSkippedReleaseTag = "latest"

        await store.waitForPendingSave()

        let writes = calls.withLock { $0 }
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.0, "latest")
        XCTAssertEqual(writes.first?.1, false)
        XCTAssertEqual(try persistedState(store).updaterSkippedReleaseTag, "latest")
        let permissions = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions]
        XCTAssertEqual((permissions as? NSNumber)?.intValue, 0o600)
    }

    func testFailedDeferredSaveRemainsAvailableToExplicitFlush() async throws {
        let directory = makeDirectory()
        try Data("blocked".utf8).write(to: directory)
        let store = RuntimeStateStore(directory: directory)
        store.updaterSkippedReleaseTag = "retry"
        await store.waitForPendingSave()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))

        try FileManager.default.removeItem(at: directory)
        store.flushNow()

        XCTAssertEqual(try persistedState(store).updaterSkippedReleaseTag, "retry")
    }

    func testImmediateSaveRemainsSynchronousAndRetryableAfterFailure() throws {
        let directory = makeDirectory()
        try Data("blocked".utf8).write(to: directory)
        let store = RuntimeStateStore(directory: directory, deferSaves: false)
        store.updaterSkippedReleaseTag = "retry"
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))

        try FileManager.default.removeItem(at: directory)
        store.flushNow()
        XCTAssertEqual(try persistedState(store).updaterSkippedReleaseTag, "retry")
        store.updaterSkippedReleaseTag = "immediate"
        XCTAssertEqual(try persistedState(store).updaterSkippedReleaseTag, "immediate")
    }

    func testUpdatesDuringWriteCoalesceToLatestSnapshot() async throws {
        let directory = makeDirectory()
        let writes = Mutex<[String]>([])
        let releaseFirst = DispatchSemaphore(value: 0)
        let (started, continuation) = AsyncStream<Void>.makeStream()
        defer { releaseFirst.signal()
            continuation.finish()
        }
        var starts = started.makeAsyncIterator()
        let store = RuntimeStateStore(directory: directory) { state, url in
            let first = writes.withLock { values in
                values.append(state.updaterSkippedReleaseTag ?? "")
                return values.count == 1
            }
            if first {
                continuation.yield(())
                releaseFirst.wait()
            }
            try RuntimeStateStore.writeState(state, to: url)
        }
        store.updaterSkippedReleaseTag = "first"
        _ = await starts.next()
        store.updaterSkippedReleaseTag = "superseded"
        store.updaterSkippedReleaseTag = "latest"
        releaseFirst.signal()
        await store.waitForPendingSave()

        XCTAssertEqual(writes.withLock { $0 }, ["first", "latest"])
        XCTAssertEqual(try persistedState(store).updaterSkippedReleaseTag, "latest")
    }

    func testOldAcknowledgmentCannotClearRestoredValueAfterSynchronousFlush() async throws {
        let directory = makeDirectory()
        let writes = Mutex<[String]>([])
        let releaseFirst = DispatchSemaphore(value: 0)
        let (started, continuation) = AsyncStream<Void>.makeStream()
        defer { releaseFirst.signal()
            continuation.finish()
        }
        var starts = started.makeAsyncIterator()
        let store = RuntimeStateStore(directory: directory) { state, url in
            let first = writes.withLock { values in
                values.append(state.updaterSkippedReleaseTag ?? "")
                return values.count == 1
            }
            if first {
                continuation.yield(())
                releaseFirst.wait()
            }
            try RuntimeStateStore.writeState(state, to: url)
        }
        store.updaterSkippedReleaseTag = "A"
        _ = await starts.next()
        store.updaterSkippedReleaseTag = "B"
        releaseFirst.signal()
        store.flushNow()
        XCTAssertEqual(try persistedState(store).updaterSkippedReleaseTag, "B")
        store.updaterSkippedReleaseTag = "A"
        await store.waitForPendingSave()

        XCTAssertEqual(writes.withLock { $0 }, ["A", "B", "A"])
        XCTAssertEqual(try persistedState(store).updaterSkippedReleaseTag, "A")
    }

    func testFailureDoesNotDiscardNewerPendingSnapshot() async throws {
        let directory = makeDirectory()
        let attempts = Mutex<[String]>([])
        let releaseFailure = DispatchSemaphore(value: 0)
        let (started, continuation) = AsyncStream<Void>.makeStream()
        defer { releaseFailure.signal()
            continuation.finish()
        }
        var starts = started.makeAsyncIterator()
        let store = RuntimeStateStore(directory: directory) { state, url in
            attempts.withLock { $0.append(state.updaterSkippedReleaseTag ?? "") }
            if state.updaterSkippedReleaseTag == "fail" {
                continuation.yield(())
                releaseFailure.wait()
                throw CocoaError(.fileWriteUnknown)
            }
            try RuntimeStateStore.writeState(state, to: url)
        }
        store.updaterSkippedReleaseTag = "fail"
        _ = await starts.next()
        store.updaterSkippedReleaseTag = "latest"
        releaseFailure.signal()
        await store.waitForPendingSave()

        XCTAssertEqual(attempts.withLock { $0 }, ["fail", "latest"])
        XCTAssertEqual(try persistedState(store).updaterSkippedReleaseTag, "latest")
    }

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeStateStoreTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func persistedState(_ store: RuntimeStateStore) throws -> RuntimeState {
        try JSONDecoder().decode(RuntimeState.self, from: Data(contentsOf: store.fileURL))
    }
}
