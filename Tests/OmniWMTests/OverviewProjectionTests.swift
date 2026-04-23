// SPDX-License-Identifier: GPL-2.0-only
import ApplicationServices
import Foundation
import Testing

@testable import OmniWM

private func makeOverviewProjectionWindow(
    model: WindowModel,
    workspaceId: WorkspaceDescriptor.ID,
    windowId: Int,
    frame: CGRect,
    title: String
) -> (handle: WindowHandle, data: OverviewWindowLayoutData) {
    let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId)
    let token = model.upsert(
        window: axRef,
        pid: pid_t(windowId),
        windowId: windowId,
        workspace: workspaceId
    )
    guard let handle = model.handle(for: token) else {
        fatalError("Expected overview projection bridge handle")
    }
    let entry = model.entry(for: handle)!
    return (
        handle,
        (
            entry: entry,
            title: title,
            appName: "App",
            appIcon: nil,
            frame: frame
        )
    )
}

private func frameIsWithinViewport(_ frame: CGRect, viewport: CGRect) -> Bool {
    frame.minX >= viewport.minX &&
        frame.maxX <= viewport.maxX &&
        frame.minY >= viewport.minY &&
        frame.maxY <= viewport.maxY
}

private func makeNiriOverviewSnapshot(
    workspaceId: WorkspaceDescriptor.ID,
    columns: [[WindowHandle]],
    preferredWidths: [CGFloat?] = [],
    widthWeights: [CGFloat] = [],
    preferredHeights: [[CGFloat]] = []
) -> NiriOverviewWorkspaceSnapshot {
    let resolvedWeights = widthWeights.isEmpty ? Array(repeating: 1.0, count: columns.count) : widthWeights
    let resolvedPreferredWidths = preferredWidths.isEmpty ? Array(repeating: nil, count: columns.count) : preferredWidths

    return NiriOverviewWorkspaceSnapshot(
        workspaceId: workspaceId,
        columns: columns.enumerated().map { index, handles in
            NiriOverviewColumnSnapshot(
                index: index,
                widthWeight: resolvedWeights[index],
                preferredWidth: resolvedPreferredWidths[index],
                tiles: handles.enumerated().map { tileIndex, handle in
                    let preferredHeight = preferredHeights.indices.contains(index) &&
                        preferredHeights[index].indices.contains(tileIndex)
                        ? preferredHeights[index][tileIndex]
                        : 1.0
                    return NiriOverviewTileSnapshot(
                        token: handle.id,
                        preferredHeight: preferredHeight
                    )
                }
            )
        }
    )
}

@MainActor
private func makeNiriOverviewLayout(
    workspaces: [OverviewWorkspaceLayoutItem],
    windows: [WindowHandle: OverviewWindowLayoutData],
    snapshots: [WorkspaceDescriptor.ID: NiriOverviewWorkspaceSnapshot],
    screenFrame: CGRect = CGRect(x: 0, y: 0, width: 1440, height: 900),
    searchQuery: String = "",
    scale: CGFloat = 1.0
) -> OverviewLayout {
    OverviewLayoutCalculator.calculateLayout(
        workspaces: workspaces,
        windows: windows,
        niriSnapshotsByWorkspace: snapshots,
        screenFrame: screenFrame,
        searchQuery: searchQuery,
        scale: scale
    )
}

@Suite struct OverviewProjectionTests {
    @Test @MainActor func localizedFrameTranslatesOffsetMonitorIntoPanelCoordinates() {
        let monitorFrame = CGRect(x: 1728, y: 0, width: 1728, height: 1117)
        let globalFrame = CGRect(x: 2048, y: 120, width: 800, height: 600)

        let localized = OverviewLayoutCalculator.localizedFrame(globalFrame, to: monitorFrame)

        #expect(localized == CGRect(x: 320, y: 120, width: 800, height: 600))
    }

    @Test @MainActor func projectedLayoutsKeepWindowsVisibleAcrossOriginAndOffsetMonitors() {
        let workspaceId = WorkspaceDescriptor.ID()
        let model = WindowModel()
        let workspaces: [OverviewWorkspaceLayoutItem] = [
            (id: workspaceId, name: "1", isActive: true)
        ]

        let first = makeOverviewProjectionWindow(
            model: model,
            workspaceId: workspaceId,
            windowId: 101,
            frame: CGRect(x: 120, y: 80, width: 900, height: 700),
            title: "Alpha"
        )
        let second = makeOverviewProjectionWindow(
            model: model,
            workspaceId: workspaceId,
            windowId: 102,
            frame: CGRect(x: 2080, y: 140, width: 960, height: 720),
            title: "Beta"
        )
        let windows: [WindowHandle: OverviewWindowLayoutData] = [
            first.handle: first.data,
            second.handle: second.data
        ]

        let originMonitor = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let offsetMonitor = CGRect(x: 1728, y: 0, width: 1728, height: 1117)
        let originViewport = OverviewLayoutCalculator.viewportFrame(for: originMonitor)
        let offsetViewport = OverviewLayoutCalculator.viewportFrame(for: offsetMonitor)

        let originLayout = OverviewLayoutCalculator.calculateLayout(
            workspaces: workspaces,
            windows: windows.mapValues { data in
                (
                    entry: data.entry,
                    title: data.title,
                    appName: data.appName,
                    appIcon: data.appIcon,
                    frame: OverviewLayoutCalculator.localizedFrame(data.frame, to: originMonitor)
                )
            },
            screenFrame: originViewport,
            searchQuery: "",
            scale: 1.0
        )
        let offsetLayout = OverviewLayoutCalculator.calculateLayout(
            workspaces: workspaces,
            windows: windows.mapValues { data in
                (
                    entry: data.entry,
                    title: data.title,
                    appName: data.appName,
                    appIcon: data.appIcon,
                    frame: OverviewLayoutCalculator.localizedFrame(data.frame, to: offsetMonitor)
                )
            },
            screenFrame: offsetViewport,
            searchQuery: "",
            scale: 1.0
        )

        #expect(originLayout.allWindows.count == 2)
        #expect(offsetLayout.allWindows.count == 2)
        #expect(originLayout.allWindows.allSatisfy { frameIsWithinViewport($0.overviewFrame, viewport: originViewport) })
        #expect(offsetLayout.allWindows.allSatisfy { frameIsWithinViewport($0.overviewFrame, viewport: offsetViewport) })
        #expect(offsetLayout.allWindows.contains { $0.originalFrame.minX < 0 })
        #expect(offsetLayout.allWindows.contains { $0.originalFrame.minX > 0 })
    }

    @Test @MainActor func zoomScaleLayoutsStayNonEmptyOnOriginAndOffsetMonitors() {
        let workspaceId = WorkspaceDescriptor.ID()
        let model = WindowModel()
        let workspaces: [OverviewWorkspaceLayoutItem] = [
            (id: workspaceId, name: "1", isActive: true)
        ]

        var windows: [WindowHandle: OverviewWindowLayoutData] = [:]
        for (index, x) in stride(from: 0, through: 2200, by: 275).enumerated() {
            let window = makeOverviewProjectionWindow(
                model: model,
                workspaceId: workspaceId,
                windowId: 200 + index,
                frame: CGRect(x: CGFloat(x), y: CGFloat(60 + (index % 3) * 80), width: 800, height: 620),
                title: "Window \(index)"
            )
            windows[window.handle] = window.data
        }

        let originMonitor = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let offsetMonitor = CGRect(x: 1728, y: 0, width: 1728, height: 1117)

        for scale in [CGFloat(1.0), 1.25] {
            for monitorFrame in [originMonitor, offsetMonitor] {
                let viewport = OverviewLayoutCalculator.viewportFrame(for: monitorFrame)
                let layout = OverviewLayoutCalculator.calculateLayout(
                    workspaces: workspaces,
                    windows: windows.mapValues { data in
                        (
                            entry: data.entry,
                            title: data.title,
                            appName: data.appName,
                            appIcon: data.appIcon,
                            frame: OverviewLayoutCalculator.localizedFrame(data.frame, to: monitorFrame)
                        )
                    },
                    screenFrame: viewport,
                    searchQuery: "",
                    scale: scale
                )

                #expect(!layout.allWindows.isEmpty)
                #expect(layout.allWindows.count == windows.count)
                #expect(layout.allWindows.allSatisfy { frameIsWithinViewport($0.overviewFrame, viewport: viewport) })
            }
        }
    }

    @Test @MainActor func localizedAnimationFramesAndZoomClampStayInPanelSpace() {
        let workspaceId = WorkspaceDescriptor.ID()
        let model = WindowModel()
        let workspaces: [OverviewWorkspaceLayoutItem] = [
            (id: workspaceId, name: "1", isActive: true)
        ]

        var windows: [WindowHandle: OverviewWindowLayoutData] = [:]
        for index in 0 ..< 10 {
            let window = makeOverviewProjectionWindow(
                model: model,
                workspaceId: workspaceId,
                windowId: 400 + index,
                frame: CGRect(
                    x: 1880 + CGFloat(index * 60),
                    y: 50 + CGFloat((index % 4) * 45),
                    width: 720,
                    height: 540
                ),
                title: "App \(index)"
            )
            windows[window.handle] = window.data
        }

        let monitorFrame = CGRect(x: 1728, y: 0, width: 1440, height: 900)
        let viewport = OverviewLayoutCalculator.viewportFrame(for: monitorFrame)
        let localizedWindows = windows.mapValues { data in
            (
                entry: data.entry,
                title: data.title,
                appName: data.appName,
                appIcon: data.appIcon,
                frame: OverviewLayoutCalculator.localizedFrame(data.frame, to: monitorFrame)
            )
        }

        let baseLayout = OverviewLayoutCalculator.calculateLayout(
            workspaces: workspaces,
            windows: localizedWindows,
            screenFrame: viewport,
            searchQuery: "",
            scale: 1.0
        )
        let zoomedLayout = OverviewLayoutCalculator.calculateLayout(
            workspaces: workspaces,
            windows: localizedWindows,
            screenFrame: viewport,
            searchQuery: "",
            scale: 1.25
        )

        let sampleWindow = zoomedLayout.allWindows.first!
        let interpolated = sampleWindow.interpolatedFrame(progress: 0.5)
        let clampedOffset = OverviewLayoutCalculator.clampedScrollOffset(
            -500,
            layout: zoomedLayout,
            screenFrame: viewport
        )
        let bounds = OverviewLayoutCalculator.scrollOffsetBounds(
            layout: zoomedLayout,
            screenFrame: viewport
        )

        #expect(zoomedLayout.resolvedScrollOffsetBounds != nil)
        #expect(sampleWindow.originalFrame.minX < viewport.maxX)
        #expect(sampleWindow.originalFrame.minX >= -monitorFrame.width)
        #expect(frameIsWithinViewport(sampleWindow.overviewFrame, viewport: viewport))
        #expect(interpolated.minX >= sampleWindow.originalFrame.minX)
        #expect(interpolated.maxX <= max(sampleWindow.originalFrame.maxX, sampleWindow.overviewFrame.maxX))
        #expect(bounds.contains(clampedOffset))
        #expect(zoomedLayout.allWindows.count == baseLayout.allWindows.count)
    }

    @Test @MainActor func genericProjectionPreservesWindowAspectRatios() {
        let workspaceId = WorkspaceDescriptor.ID()
        let model = WindowModel()
        let workspaces: [OverviewWorkspaceLayoutItem] = [
            (id: workspaceId, name: "1", isActive: true)
        ]

        let wide = makeOverviewProjectionWindow(
            model: model,
            workspaceId: workspaceId,
            windowId: 450,
            frame: CGRect(x: 40, y: 120, width: 1200, height: 320),
            title: "Wide"
        )
        let tall = makeOverviewProjectionWindow(
            model: model,
            workspaceId: workspaceId,
            windowId: 451,
            frame: CGRect(x: 1280, y: 120, width: 320, height: 960),
            title: "Tall"
        )

        let layout = OverviewLayoutCalculator.calculateLayout(
            workspaces: workspaces,
            windows: [
                wide.handle: wide.data,
                tall.handle: tall.data
            ],
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            searchQuery: "",
            scale: 1.0
        )

        guard let widePreview = layout.window(for: wide.handle)?.overviewFrame,
              let tallPreview = layout.window(for: tall.handle)?.overviewFrame
        else {
            Issue.record("Expected projected generic windows")
            return
        }

        #expect((widePreview.width / widePreview.height).isApproximatelyEqual(
            to: wide.data.frame.width / wide.data.frame.height,
            tolerance: 0.02
        ))
        #expect((tallPreview.width / tallPreview.height).isApproximatelyEqual(
            to: tall.data.frame.width / tall.data.frame.height,
            tolerance: 0.02
        ))
    }

    @Test @MainActor func genericProjectionHandlesSingleWindowWithoutLeavingViewport() {
        let workspaceId = WorkspaceDescriptor.ID()
        let model = WindowModel()
        let workspaces: [OverviewWorkspaceLayoutItem] = [
            (id: workspaceId, name: "1", isActive: true)
        ]
        let viewport = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let window = makeOverviewProjectionWindow(
            model: model,
            workspaceId: workspaceId,
            windowId: 480,
            frame: CGRect(x: 220, y: 140, width: 960, height: 640),
            title: "Solo"
        )

        let layout = OverviewLayoutCalculator.calculateLayout(
            workspaces: workspaces,
            windows: [window.handle: window.data],
            screenFrame: viewport,
            searchQuery: "",
            scale: 1.0
        )

        guard let projectedFrame = layout.window(for: window.handle)?.overviewFrame else {
            Issue.record("Expected projected single window")
            return
        }

        #expect(layout.allWindows.count == 1)
        #expect(frameIsWithinViewport(projectedFrame, viewport: viewport))
        #expect(projectedFrame.width > 0)
        #expect(projectedFrame.height > 0)
    }

    @Test @MainActor func genericProjectionBreaksNearEqualFrameTiesByTitle() {
        let workspaceId = WorkspaceDescriptor.ID()
        let model = WindowModel()
        let workspaces: [OverviewWorkspaceLayoutItem] = [
            (id: workspaceId, name: "1", isActive: true)
        ]

        let beta = makeOverviewProjectionWindow(
            model: model,
            workspaceId: workspaceId,
            windowId: 490,
            frame: CGRect(x: 120.4, y: 100, width: 800, height: 520),
            title: "Beta"
        )
        let alpha = makeOverviewProjectionWindow(
            model: model,
            workspaceId: workspaceId,
            windowId: 491,
            frame: CGRect(x: 120.0, y: 100, width: 800, height: 520),
            title: "Alpha"
        )

        let layout = OverviewLayoutCalculator.calculateLayout(
            workspaces: workspaces,
            windows: [
                beta.handle: beta.data,
                alpha.handle: alpha.data
            ],
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            searchQuery: "",
            scale: 1.0
        )

        #expect(layout.workspaceSections.first?.windows.map(\.handle) == [alpha.handle, beta.handle])
    }

    @Test @MainActor func niriProjectionFollowsEngineTileOrderWhenFramesDisagree() {
        let workspaceId = WorkspaceDescriptor.ID()
        let model = WindowModel()
        let workspaces: [OverviewWorkspaceLayoutItem] = [
            (id: workspaceId, name: "1", isActive: true)
        ]

        let visualTop = makeOverviewProjectionWindow(
            model: model,
            workspaceId: workspaceId,
            windowId: 501,
            frame: CGRect(x: 80, y: 40, width: 700, height: 520),
            title: "Top"
        )
        let visualBottom = makeOverviewProjectionWindow(
            model: model,
            workspaceId: workspaceId,
            windowId: 502,
            frame: CGRect(x: 80, y: 720, width: 700, height: 520),
            title: "Bottom"
        )

        let engine = NiriLayoutEngine()
        let root = NiriRoot(workspaceId: workspaceId)
        engine.roots[workspaceId] = root

        let column = NiriContainer()
        root.appendChild(column)

        let bottomNode = NiriWindow(token: visualBottom.handle.id)
        let topNode = NiriWindow(token: visualTop.handle.id)
        column.appendChild(bottomNode)
        column.appendChild(topNode)
        engine.tokenToNode[bottomNode.token] = bottomNode
        engine.tokenToNode[topNode.token] = topNode

        guard let snapshot = engine.overviewSnapshot(for: workspaceId) else {
            Issue.record("Expected Niri overview snapshot")
            return
        }

        let layout = makeNiriOverviewLayout(
            workspaces: workspaces,
            windows: [
                visualTop.handle: visualTop.data,
                visualBottom.handle: visualBottom.data
            ],
            snapshots: [workspaceId: snapshot]
        )

        let orderedHandles = layout.niriColumnsByWorkspace[workspaceId]?.first?.windowHandles ?? []

        #expect(orderedHandles == [visualTop.handle, visualBottom.handle])
        #expect(layout.window(for: visualTop.handle)?.overviewFrame.maxY ?? 0 >
            layout.window(for: visualBottom.handle)?.overviewFrame.maxY ?? 0)
    }

    @Test @MainActor func niriGapHitTestingPrefersColumnInsertTarget() {
        let workspaceId = WorkspaceDescriptor.ID()
        let model = WindowModel()
        let workspaces: [OverviewWorkspaceLayoutItem] = [
            (id: workspaceId, name: "1", isActive: true)
        ]

        let left = makeOverviewProjectionWindow(
            model: model,
            workspaceId: workspaceId,
            windowId: 601,
            frame: CGRect(x: 100, y: 120, width: 720, height: 540),
            title: "Left"
        )
        let right = makeOverviewProjectionWindow(
            model: model,
            workspaceId: workspaceId,
            windowId: 602,
            frame: CGRect(x: 980, y: 120, width: 720, height: 540),
            title: "Right"
        )

        let layout = makeNiriOverviewLayout(
            workspaces: workspaces,
            windows: [
                left.handle: left.data,
                right.handle: right.data
            ],
            snapshots: [
                workspaceId: makeNiriOverviewSnapshot(
                    workspaceId: workspaceId,
                    columns: [[left.handle], [right.handle]]
                )
            ]
        )

        guard let zone = layout.niriColumnDropZonesByWorkspace[workspaceId]?.first(where: { $0.insertIndex == 1 }) else {
            Issue.record("Expected between-column drop zone")
            return
        }

        let point = CGPoint(x: zone.frame.midX, y: zone.frame.midY)
        let target = layout.resolveDragTarget(at: point, draggedHandle: nil)

        #expect(target == .niriColumnInsert(workspaceId: workspaceId, insertIndex: 1))
    }

    @Test @MainActor func niriProjectionUsesActualColumnCountInsteadOfGenericFourColumnCap() {
        let workspaceId = WorkspaceDescriptor.ID()
        let model = WindowModel()
        let workspaces: [OverviewWorkspaceLayoutItem] = [
            (id: workspaceId, name: "1", isActive: true)
        ]

        var windows: [WindowHandle: OverviewWindowLayoutData] = [:]
        var columnHandles: [[WindowHandle]] = []
        for index in 0 ..< 5 {
            let window = makeOverviewProjectionWindow(
                model: model,
                workspaceId: workspaceId,
                windowId: 700 + index,
                frame: CGRect(x: CGFloat(80 + index * 220), y: 120, width: 720, height: 540),
                title: "Window \(index)"
            )
            windows[window.handle] = window.data
            columnHandles.append([window.handle])
        }

        let genericLayout = OverviewLayoutCalculator.calculateLayout(
            workspaces: workspaces,
            windows: windows,
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            searchQuery: "",
            scale: 1.0
        )
        let niriLayout = makeNiriOverviewLayout(
            workspaces: workspaces,
            windows: windows,
            snapshots: [
                workspaceId: makeNiriOverviewSnapshot(
                    workspaceId: workspaceId,
                    columns: columnHandles
                )
            ]
        )

        let genericDistinctColumns = Set(genericLayout.allWindows.map { Int($0.overviewFrame.minX.rounded()) }).count
        let niriColumns = niriLayout.niriColumnsByWorkspace[workspaceId] ?? []

        #expect(genericDistinctColumns == 5)
        #expect(niriColumns.count == 5)
        #expect(niriLayout.niriColumnDropZonesByWorkspace[workspaceId]?.count == 6)
    }

    @Test @MainActor func niriProjectionPreservesTileHeightRatios() {
        let workspaceId = WorkspaceDescriptor.ID()
        let model = WindowModel()
        let workspaces: [OverviewWorkspaceLayoutItem] = [
            (id: workspaceId, name: "1", isActive: true)
        ]

        let top = makeOverviewProjectionWindow(
            model: model,
            workspaceId: workspaceId,
            windowId: 750,
            frame: CGRect(x: 80, y: 520, width: 720, height: 420),
            title: "Top"
        )
        let bottom = makeOverviewProjectionWindow(
            model: model,
            workspaceId: workspaceId,
            windowId: 751,
            frame: CGRect(x: 80, y: 120, width: 720, height: 180),
            title: "Bottom"
        )

        let layout = makeNiriOverviewLayout(
            workspaces: workspaces,
            windows: [
                top.handle: top.data,
                bottom.handle: bottom.data
            ],
            snapshots: [
                workspaceId: makeNiriOverviewSnapshot(
                    workspaceId: workspaceId,
                    columns: [[top.handle, bottom.handle]],
                    preferredHeights: [[420, 180]]
                )
            ]
        )

        guard let topFrame = layout.window(for: top.handle)?.overviewFrame,
              let bottomFrame = layout.window(for: bottom.handle)?.overviewFrame
        else {
            Issue.record("Expected projected Niri windows")
            return
        }

        #expect((topFrame.height / bottomFrame.height).isApproximatelyEqual(to: 420.0 / 180.0, tolerance: 0.05))
    }

    @Test @MainActor func niriProjectionRebuildsFromMutatedWorkspaceAndEngineStateBeforeRelayout() {
        let sourceWorkspaceId = WorkspaceDescriptor.ID()
        let targetWorkspaceId = WorkspaceDescriptor.ID()
        let model = WindowModel()
        let workspaces: [OverviewWorkspaceLayoutItem] = [
            (id: sourceWorkspaceId, name: "1", isActive: false),
            (id: targetWorkspaceId, name: "2", isActive: true)
        ]

        let moved = makeOverviewProjectionWindow(
            model: model,
            workspaceId: sourceWorkspaceId,
            windowId: 801,
            frame: CGRect(x: 60, y: 80, width: 760, height: 560),
            title: "Moved"
        )
        let fallback = makeOverviewProjectionWindow(
            model: model,
            workspaceId: sourceWorkspaceId,
            windowId: 802,
            frame: CGRect(x: 340, y: 720, width: 760, height: 560),
            title: "Fallback"
        )
        let focused = makeOverviewProjectionWindow(
            model: model,
            workspaceId: targetWorkspaceId,
            windowId: 803,
            frame: CGRect(x: 1120, y: 120, width: 760, height: 560),
            title: "Focused"
        )

        let engine = NiriLayoutEngine(maxWindowsPerColumn: 3, maxVisibleColumns: 3)
        let movedNode = engine.addWindow(token: moved.handle.id, to: sourceWorkspaceId, afterSelection: nil)
        let fallbackNode = engine.addWindow(
            token: fallback.handle.id,
            to: sourceWorkspaceId,
            afterSelection: movedNode.id
        )
        let focusedNode = engine.addWindow(token: focused.handle.id, to: targetWorkspaceId, afterSelection: nil)

        var sourceState = ViewportState()
        sourceState.selectedNodeId = movedNode.id
        var targetState = ViewportState()
        targetState.selectedNodeId = focusedNode.id

        let moveResult = engine.moveWindowToWorkspace(
            movedNode,
            from: sourceWorkspaceId,
            to: targetWorkspaceId,
            sourceState: &sourceState,
            targetState: &targetState
        )
        guard let relocatedNode = engine.findNode(for: moved.handle.id) else {
            Issue.record("Expected moved window in target workspace")
            return
        }

        var targetInsertState = targetState
        let inserted = engine.insertWindowInNewColumn(
            relocatedNode,
            insertIndex: 1,
            in: targetWorkspaceId,
            state: &targetInsertState,
            workingFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            gaps: 8
        )

        fallbackNode.resolvedHeight = 320
        focusedNode.resolvedHeight = 540
        relocatedNode.resolvedHeight = 240

        model.updateWorkspace(for: moved.handle.id, workspace: targetWorkspaceId)

        guard let targetSnapshot = engine.overviewSnapshot(for: targetWorkspaceId),
              let sourceSnapshot = engine.overviewSnapshot(for: sourceWorkspaceId)
        else {
            Issue.record("Expected snapshots for both workspaces")
            return
        }

        let layout = makeNiriOverviewLayout(
            workspaces: workspaces,
            windows: [
                moved.handle: moved.data,
                fallback.handle: fallback.data,
                focused.handle: focused.data
            ],
            snapshots: [
                sourceWorkspaceId: sourceSnapshot,
                targetWorkspaceId: targetSnapshot
            ]
        )

        let targetColumns = layout.niriColumnsByWorkspace[targetWorkspaceId] ?? []
        let sourceFallbackFrame = layout.window(for: fallback.handle)?.overviewFrame
        let targetFocusedFrame = layout.window(for: focused.handle)?.overviewFrame
        let targetMovedFrame = layout.window(for: moved.handle)?.overviewFrame

        #expect(moveResult?.newFocusNodeId == fallbackNode.id)
        #expect(sourceState.selectedNodeId == fallbackNode.id)
        #expect(inserted)
        #expect(targetColumns.map(\.windowHandles) == [[focused.handle], [moved.handle]])
        #expect(sourceFallbackFrame != nil)
        #expect(targetFocusedFrame != nil)
        #expect(targetMovedFrame != nil)
        #expect((targetFocusedFrame!.height / targetMovedFrame!.height).isApproximatelyEqual(to: 540.0 / 240.0, tolerance: 0.05))
    }
}

private extension CGFloat {
    func isApproximatelyEqual(to other: CGFloat, tolerance: CGFloat) -> Bool {
        abs(self - other) <= tolerance
    }
}
