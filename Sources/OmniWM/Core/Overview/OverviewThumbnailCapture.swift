// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Carbon
import Foundation
import QuartzCore
import ScreenCaptureKit

@MainActor
final class OverviewThumbnailCapture {
    private weak var wmController: WMController?
    private let environment: OverviewEnvironment
    private let ownedWindowRegistry: OwnedWindowRegistry
    private let overviewSnapshot: OverviewSnapshot
    private let projection: OverviewViewportProjection
    private let windowSession: OverviewWindowSession
    private(set) var thumbnailCache: [Int: CGImage] = [:]
    private var thumbnailCaptureTask: Task<Void, Never>?
    private static let maxConcurrentThumbnailCaptures = 4
    private struct ThumbnailCaptureItem: @unchecked Sendable {
        let request: OverviewThumbnailCaptureRequest
        let scWindow: SCWindow
    }

    init(
        wmController: WMController,
        environment: OverviewEnvironment,
        ownedWindowRegistry: OwnedWindowRegistry,
        snapshot: OverviewSnapshot,
        projection: OverviewViewportProjection,
        windowSession: OverviewWindowSession
    ) {
        self.wmController = wmController
        self.environment = environment
        self.ownedWindowRegistry = ownedWindowRegistry
        overviewSnapshot = snapshot
        self.projection = projection
        self.windowSession = windowSession
    }

    func clear() {
        thumbnailCaptureTask?.cancel()
        thumbnailCaptureTask = nil
        thumbnailCache.removeAll()
    }

    func remove(windowId: Int) {
        thumbnailCache.removeValue(forKey: windowId)
    }

    func startThumbnailCapture(windowIds: Set<Int>? = nil) {
        guard CGPreflightScreenCaptureAccess() else {
            thumbnailCaptureTask?.cancel()
            return
        }
        startThumbnailCapture { [weak self] in
            await self?.captureThumbnails(windowIds: windowIds)
        }
    }

    @discardableResult
    private func startThumbnailCapture(_ capture: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        thumbnailCaptureTask?.cancel()
        environment.onThumbnailCaptureStarted()
        let task = Task(operation: capture)
        thumbnailCaptureTask = task
        return task
    }

    private func captureThumbnails(windowIds: Set<Int>?) async {
        let requests = thumbnailCaptureRequests(windowIds: windowIds)

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let eligibleWindows = content.windows.compactMap { scWindow -> (CGWindowID, SCWindow)? in
                let windowNumber = Int(scWindow.windowID)
                guard ownedWindowRegistry.isCaptureEligible(windowNumber: windowNumber) else { return nil }
                return (scWindow.windowID, scWindow)
            }
            let windowMap = Dictionary(uniqueKeysWithValues: eligibleWindows)
            let captures = requests.compactMap { request -> ThumbnailCaptureItem? in
                guard let scWindow = windowMap[CGWindowID(request.windowId)] else { return nil }
                return ThumbnailCaptureItem(request: request, scWindow: scWindow)
            }

            await captureThumbnails(captures) { item in
                guard !Task.isCancelled else { return (item.request.windowId, nil) }
                return (
                    item.request.windowId,
                    await Self.captureWindowThumbnail(scWindow: item.scWindow, request: item.request)
                )
            }
        } catch {
            FallbackFiringRecorder.shared.note(.capture, "overviewContentException")
            return
        }
    }

    private func captureThumbnails<Capture: Sendable>(
        _ captures: [Capture],
        capture: @escaping @Sendable (Capture) async -> (windowId: Int, thumbnail: CGImage?)
    ) async {
        await withTaskGroup(of: (windowId: Int, thumbnail: CGImage?).self) { group in
            var nextIndex = 0
            func addNextCapture() {
                guard nextIndex < captures.count, !Task.isCancelled else { return }
                let item = captures[nextIndex]
                nextIndex += 1
                group.addTask { await capture(item) }
            }

            for _ in 0 ..< min(Self.maxConcurrentThumbnailCaptures, captures.count) {
                addNextCapture()
            }
            while let result = await group.next() {
                guard !Task.isCancelled else { return }
                if let thumbnail = result.thumbnail {
                    thumbnailCache[result.windowId] = thumbnail
                }
                addNextCapture()
            }
        }

        guard !Task.isCancelled else { return }
        windowSession.updateWindowThumbnails(thumbnailCache)
    }

    #if DEBUG
        @discardableResult
        func startThumbnailCaptureForTests(
            windowId: Int,
            capture: @escaping @Sendable () async -> CGImage?
        ) -> Task<Void, Never> {
            startThumbnailCapture {
                await self.captureThumbnails([windowId]) { windowId in
                    (windowId, await capture())
                }
            }
        }
    #endif

    private func thumbnailCaptureRequests(windowIds: Set<Int>? = nil) -> [OverviewThumbnailCaptureRequest] {
        guard let wmController else { return [] }

        let scaleByMonitorId = wmController.workspaceManager.monitors
            .reduce(into: [Monitor.ID: CGFloat]()) { scales, monitor in
                scales[monitor.id] = monitorBackingScaleFactor(for: monitor.displayId)
            }

        var projections: [OverviewThumbnailProjection] = []
        projections.reserveCapacity(projection.layoutsByMonitor.values.reduce(0) { partialResult, layout in
            partialResult + layout.allWindows.count
        })

        for (monitorId, layout) in projection.layoutsByMonitor {
            let scaleFactor = scaleByMonitorId[monitorId] ?? 1.0
            for window in layout.allWindows {
                projections.append(
                    OverviewThumbnailProjection(
                        windowId: window.windowId,
                        overviewFrame: window.overviewFrame,
                        backingScaleFactor: scaleFactor
                    )
                )
            }
        }

        return OverviewThumbnailSizing.captureRequests(
            windowIds: windowIds.map { Array($0).sorted() } ?? overviewSnapshot.windowIds,
            projections: projections
        )
    }

    private nonisolated static func captureWindowThumbnail(
        scWindow: SCWindow,
        request: OverviewThumbnailCaptureRequest
    ) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()

        config.width = request.pixelWidth
        config.height = request.pixelHeight
        config.showsCursor = false
        config.capturesAudio = false
        config.scalesToFit = true

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return image
        } catch {
            FallbackFiringRecorder.shared.note(.capture, "screenshotException")
            return nil
        }
    }

    private func monitorBackingScaleFactor(for displayId: CGDirectDisplayID) -> CGFloat {
        NSScreen.screens.first(where: { $0.displayId == displayId })?.backingScaleFactor ?? 1.0
    }
}
