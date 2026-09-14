// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import ScreenCaptureKit

struct OverviewPreviewRequest: Equatable {
    let handle: WindowHandle
    let token: WindowToken
    let pixelWidth: Int
    let pixelHeight: Int

    init(handle: WindowHandle, pixelWidth: Int, pixelHeight: Int) {
        self.handle = handle
        token = handle.token
        self.pixelWidth = max(1, pixelWidth)
        self.pixelHeight = max(1, pixelHeight)
    }
}

@MainActor
final class OverviewThumbnailCapture {
    typealias StreamFactory = @MainActor (OverviewPreviewRequest, OverviewPreviewStream) async throws
        -> any OverviewPreviewStreamControl

    private enum Status {
        case queued, starting, running, failed
    }

    private final class Source {
        let id: UInt64
        let generation: UInt64
        let request: OverviewPreviewRequest
        var status = Status.queued
        var output: OverviewPreviewStream?
        var control: (any OverviewPreviewStreamControl)?

        init(id: UInt64, generation: UInt64, request: OverviewPreviewRequest) {
            self.id = id
            self.generation = generation
            self.request = request
        }
    }

    private let environment: OverviewEnvironment
    private let ownedWindowRegistry: OwnedWindowRegistry
    private let hasCaptureAccess: @MainActor () -> Bool
    private let streamFactory: StreamFactory?
    private var generation: UInt64 = 1
    private var nextSourceId: UInt64 = 0
    private var sources: [ObjectIdentifier: Source] = [:]
    private var sourceOrder: [ObjectIdentifier] = []
    private var starts: [UInt64: Task<Void, Never>] = [:]
    private var discoveryTask: Task<Void, Never>?
    private var windowsByToken: [WindowToken: SCWindow] = [:]
    private(set) var previewCache: [WindowHandle: OverviewPreviewFrame] = [:]
    var onPreview: @MainActor (WindowHandle, OverviewPreviewFrame?) -> Void = { _, _ in }

    init(
        environment: OverviewEnvironment,
        ownedWindowRegistry: OwnedWindowRegistry,
        hasCaptureAccess: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
        streamFactory: StreamFactory? = nil
    ) {
        self.environment = environment
        self.ownedWindowRegistry = ownedWindowRegistry
        self.hasCaptureAccess = hasCaptureAccess
        self.streamFactory = streamFactory
    }

    func reconcile(represented: Set<WindowHandle>, visible: [OverviewPreviewRequest]) {
        for handle in Array(previewCache.keys) where !represented.contains(handle) {
            previewCache.removeValue(forKey: handle)
            onPreview(handle, nil)
        }
        var requests: [ObjectIdentifier: OverviewPreviewRequest] = [:]
        sourceOrder.removeAll(keepingCapacity: true)
        for request in visible where represented.contains(request.handle) && request.token == request.handle.token {
            let key = ObjectIdentifier(request.handle)
            if let previous = requests[key] {
                requests[key] = OverviewPreviewRequest(
                    handle: request.handle,
                    pixelWidth: max(previous.pixelWidth, request.pixelWidth),
                    pixelHeight: max(previous.pixelHeight, request.pixelHeight)
                )
            } else {
                requests[key] = request
                sourceOrder.append(key)
            }
        }
        for (key, source) in sources where requests[key]?.token != source.request.token {
            retire(source)
            sources.removeValue(forKey: key)
        }
        guard !requests.isEmpty, hasCaptureAccess() else {
            for source in sources.values { retire(source) }
            sources.removeAll()
            return
        }
        var added = false
        for key in sourceOrder {
            guard sources[key] == nil, let request = requests[key] else { continue }
            nextSourceId &+= 1
            sources[key] = Source(id: nextSourceId, generation: generation, request: request)
            added = true
        }
        if added { environment.onThumbnailCaptureStarted() }
        startQueuedSources()
    }

    func remove(handle: WindowHandle) {
        let key = ObjectIdentifier(handle)
        if let source = sources.removeValue(forKey: key) { retire(source) }
        sourceOrder.removeAll { $0 == key }
        previewCache.removeValue(forKey: handle)
        onPreview(handle, nil)
    }

    func clear() {
        generation &+= 1
        discoveryTask?.cancel()
        discoveryTask = nil
        windowsByToken.removeAll()
        for source in sources.values { retire(source) }
        sources.removeAll()
        sourceOrder.removeAll()
        let handles = Array(previewCache.keys)
        previewCache.removeAll()
        for handle in handles { onPreview(handle, nil) }
    }

    private func retire(_ source: Source) {
        source.output?.invalidate()
        if source.status == .starting {
            starts[source.id]?.cancel()
        } else {
            source.control?.stop()
            source.control = nil
        }
    }

    private func startQueuedSources() {
        for key in sourceOrder {
            guard starts.count < 4 else { return }
            guard let source = sources[key], source.status == .queued else { continue }
            source.status = .starting
            let sourceId = source.id
            let output = OverviewPreviewStream(
                onReady: { [weak self] in
                    Task { @MainActor [weak self] in self?.publish(key: key, sourceId: sourceId) }
                },
                onFailure: { [weak self] in
                    Task { @MainActor [weak self] in self?.streamFailed(key: key, sourceId: sourceId) }
                }
            )
            source.output = output
            starts[source.id] = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let control = try await makeControl(request: source.request, output: output)
                    try Task.checkCancellation()
                    source.control = control
                    try await control.start()
                    finishStarting(source, failed: false)
                } catch {
                    if !(error is CancellationError) {
                        FallbackFiringRecorder.shared.note(.capture, "overviewStreamStartException")
                    }
                    finishStarting(source, failed: true)
                }
            }
        }
    }

    private func finishStarting(_ source: Source, failed: Bool) {
        starts.removeValue(forKey: source.id)
        if isCurrent(source), !failed, source.status != .failed {
            source.status = .running
        } else {
            source.output?.invalidate()
            source.control?.stop()
            source.control = nil
            source.status = .failed
        }
        startQueuedSources()
    }

    private func isCurrent(_ source: Source) -> Bool {
        source.generation == generation && sources[ObjectIdentifier(source.request.handle)] === source &&
            source.request.handle.token == source.request.token
    }

    private func publish(key: ObjectIdentifier, sourceId: UInt64) {
        guard let source = sources[key], source.id == sourceId,
              isCurrent(source), source.status != .failed,
              let frame = source.output?.take()
        else { return }
        previewCache[source.request.handle] = frame
        onPreview(source.request.handle, frame)
    }

    private func streamFailed(key: ObjectIdentifier, sourceId: UInt64) {
        guard let source = sources[key], source.id == sourceId, isCurrent(source) else { return }
        source.output?.invalidate()
        source.status = .failed
        source.control = nil
        FallbackFiringRecorder.shared.note(.capture, "overviewStreamException")
    }

    private func makeControl(
        request: OverviewPreviewRequest,
        output: OverviewPreviewStream
    ) async throws -> any OverviewPreviewStreamControl {
        if let streamFactory { return try await streamFactory(request, output) }
        if windowsByToken[request.token] == nil { await discoverWindows() }
        try Task.checkCancellation()
        guard let window = windowsByToken[request.token], request.token == request.handle.token else {
            throw CancellationError()
        }
        return try OverviewNativePreviewStream(window: window, request: request, output: output)
    }

    private func discoverWindows() async {
        if let discoveryTask {
            await discoveryTask.value
            return
        }
        let expectedGeneration = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                guard !Task.isCancelled, generation == expectedGeneration else { return }
                windowsByToken = Dictionary(uniqueKeysWithValues: content.windows.compactMap { window in
                    guard let app = window.owningApplication,
                          ownedWindowRegistry.isCaptureEligible(windowNumber: Int(window.windowID))
                    else { return nil }
                    return (WindowToken(pid: app.processID, windowId: Int(window.windowID)), window)
                })
            } catch {
                FallbackFiringRecorder.shared.note(.capture, "overviewContentException")
            }
        }
        discoveryTask = task
        await task.value
        if generation == expectedGeneration { discoveryTask = nil }
    }
}
