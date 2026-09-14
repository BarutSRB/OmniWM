// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import Synchronization
import XCTest

final class OverviewPreviewCaptureTests: XCTestCase {
    func testMailboxKeepsOnlyLatestFrameAndSchedulesOneDrain() throws {
        let callbacks = Mutex(0)
        let output = OverviewPreviewStream(onReady: { callbacks.withLock { $0 += 1 } }, onFailure: {})
        let first = try makeOverviewPreviewFrame()
        let last = try makeOverviewPreviewFrame()
        output.offer(first)
        output.offer(last)
        XCTAssertEqual(callbacks.withLock { $0 }, 1)
        XCTAssertTrue(output.take() === last)
        XCTAssertNil(output.take())
        output.offer(first)
        XCTAssertEqual(callbacks.withLock { $0 }, 2)
        output.invalidate()
        XCTAssertNil(output.take())
        output.offer(last)
        XCTAssertNil(output.take())
        XCTAssertEqual(callbacks.withLock { $0 }, 2)
    }

    func testFrameNormalizesRetinaContentRectangle() throws {
        let frame = try makeOverviewPreviewFrame(
            width: 200,
            height: 100,
            contentRect: CGRect(x: 10, y: 5, width: 80, height: 40),
            scaleFactor: 2
        )
        XCTAssertEqual(frame.contentsRect, CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        XCTAssertEqual(frame.surface.width, 200)
        XCTAssertEqual(frame.surface.height, 100)
    }

    func testMailboxReleasesOverwrittenAndInvalidatedFrames() throws {
        let output = OverviewPreviewStream(onReady: {}, onFailure: {})
        var first: OverviewPreviewFrame? = try makeOverviewPreviewFrame()
        weak let firstLifetime = first
        output.offer(try XCTUnwrap(first))
        first = nil
        XCTAssertNotNil(firstLifetime)
        var second: OverviewPreviewFrame? = try makeOverviewPreviewFrame()
        weak let secondLifetime = second
        output.offer(try XCTUnwrap(second))
        second = nil
        XCTAssertNil(firstLifetime)
        XCTAssertNotNil(secondLifetime)
        output.invalidate()
        XCTAssertNil(secondLifetime)
    }

    @MainActor
    func testFirstPreviewPublishesBeforeOtherSourcesStartOrProduceFrames() async throws {
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture()
        let first = WindowHandle(id: WindowToken(pid: 123, windowId: 1))
        let second = WindowHandle(id: WindowToken(pid: 123, windowId: 2))
        capture.reconcile(represented: [first, second], visible: [
            OverviewPreviewRequest(handle: first, pixelWidth: 80, pixelHeight: 60),
            OverviewPreviewRequest(handle: second, pixelWidth: 80, pixelHeight: 60)
        ])
        await driver.waitForStarts(2)
        driver.streams[0].completeStart()
        let frame = try makeOverviewPreviewFrame()
        let published = expectation(description: "first source publishes independently")
        capture.onPreview = { handle, preview in
            if handle === first, preview != nil { published.fulfill() }
        }
        driver.streams[0].output.offer(frame)
        await fulfillment(of: [published], timeout: 1)
        XCTAssertTrue(capture.previewCache[first] === frame)
        XCTAssertNil(capture.previewCache[second])
        capture.clear()
        driver.completeAllStarts()
        await driver.waitForStops(2)
    }

    @MainActor
    func testCaptureDeduplicatesPanelsAndPreservesRunningDimensions() async throws {
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture()
        let handle = WindowHandle(id: WindowToken(pid: 123, windowId: 456))
        capture.reconcile(represented: [handle], visible: [
            OverviewPreviewRequest(handle: handle, pixelWidth: 100, pixelHeight: 60),
            OverviewPreviewRequest(handle: handle, pixelWidth: 200, pixelHeight: 80)
        ])
        await driver.waitForStarts(1)
        XCTAssertEqual(driver.streams.count, 1)
        XCTAssertEqual(driver.streams[0].request.pixelWidth, 200)
        XCTAssertEqual(driver.streams[0].request.pixelHeight, 80)
        driver.completeAllStarts()
        capture.reconcile(represented: [handle], visible: [
            OverviewPreviewRequest(handle: handle, pixelWidth: 400, pixelHeight: 200)
        ])
        XCTAssertEqual(driver.streams.count, 1)
        XCTAssertEqual(driver.streams[0].request.pixelWidth, 200)
        capture.clear()
    }

    @MainActor
    func testCaptureLimitsStartsAndRetiresLateStart() async throws {
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture()
        let handles = (1 ... 6).map { WindowHandle(id: WindowToken(pid: 123, windowId: $0)) }
        let requests = handles.map { OverviewPreviewRequest(handle: $0, pixelWidth: 80, pixelHeight: 60) }
        capture.reconcile(represented: Set(handles), visible: requests)
        await driver.waitForStarts(4)
        XCTAssertEqual(driver.streams.count, 4)
        driver.streams[0].completeStart()
        await driver.waitForStarts(5)
        XCTAssertEqual(driver.streams.count, 5)
        capture.clear()
        driver.completeAllStarts()
        let laterHandle = WindowHandle(id: WindowToken(pid: 123, windowId: 99))
        capture.reconcile(represented: [laterHandle], visible: [
            OverviewPreviewRequest(handle: laterHandle, pixelWidth: 80, pixelHeight: 60)
        ])
        await driver.waitForStarts(6)
        await driver.waitForStops(5)
        XCTAssertEqual(driver.streams.filter { $0.stopCount == 1 }.count, 5)
        XCTAssertTrue(capture.previewCache.isEmpty)
        driver.completeAllStarts()
        capture.clear()
    }

    @MainActor
    func testInvisiblePreviewKeepsLastFrameButRemovalRetiresIt() async throws {
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture()
        let handle = WindowHandle(id: WindowToken(pid: 123, windowId: 456))
        capture.reconcile(represented: [handle], visible: [
            OverviewPreviewRequest(handle: handle, pixelWidth: 80, pixelHeight: 60)
        ])
        await driver.waitForStarts(1)
        let frame = try makeOverviewPreviewFrame()
        let published = expectation(description: "first complete frame")
        capture.onPreview = { _, image in if image != nil { published.fulfill() } }
        driver.streams[0].output.offer(frame)
        await fulfillment(of: [published], timeout: 1)
        driver.completeAllStarts()
        capture.reconcile(represented: [handle], visible: [])
        XCTAssertTrue(capture.previewCache[handle] === frame)
        capture.reconcile(represented: [], visible: [])
        XCTAssertNil(capture.previewCache[handle])
    }

    @MainActor
    func testReusedWindowNumberDoesNotReceiveRetiredFrames() async throws {
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture()
        let token = WindowToken(pid: 123, windowId: 456)
        let first = WindowHandle(id: token)
        let second = WindowHandle(id: token)
        capture.reconcile(represented: [first], visible: [
            OverviewPreviewRequest(handle: first, pixelWidth: 80, pixelHeight: 60)
        ])
        await driver.waitForStarts(1)
        let frame = try makeOverviewPreviewFrame()
        driver.streams[0].output.offer(frame)
        capture.reconcile(represented: [second], visible: [
            OverviewPreviewRequest(handle: second, pixelWidth: 80, pixelHeight: 60)
        ])
        driver.completeAllStarts()
        await driver.waitForStarts(2)
        await driver.waitForStops(1)
        XCTAssertTrue(capture.previewCache.isEmpty)
        XCTAssertEqual(driver.streams[0].stopCount, 1)
        driver.streams[0].output.offer(frame)
        XCTAssertNil(driver.streams[0].output.take())
        driver.completeAllStarts()
        capture.clear()
    }
}
