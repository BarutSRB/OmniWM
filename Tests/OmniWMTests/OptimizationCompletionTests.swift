import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

private func makeAXWindowRef(windowId: Int) -> AXWindowRef {
    AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId)
}

private func makeOverviewWindowItem(
    handle: WindowHandle,
    workspaceId: WorkspaceDescriptor.ID,
    title: String
) -> OverviewWindowItem {
    OverviewWindowItem(
        handle: handle,
        windowId: Int.random(in: 1 ... 100_000),
        workspaceId: workspaceId,
        thumbnail: nil,
        title: title,
        appName: "App",
        appIcon: nil,
        originalFrame: .zero,
        overviewFrame: .zero,
        isHovered: false,
        isSelected: false,
        matchesSearch: true,
        closeButtonHovered: false
    )
}

@Suite struct OptimizationCompletionTests {
    @MainActor
    @Test func appInfoCacheEvictRemovesCachedEntry() {
        let cache = AppInfoCache()
        let pid = getpid()

        guard cache.info(for: pid) != nil else {
            #expect(cache.hasCachedInfo(for: pid) == false)
            return
        }

        #expect(cache.hasCachedInfo(for: pid))
        cache.evict(pid: pid)
        #expect(cache.hasCachedInfo(for: pid) == false)
    }

    @Test func windowModelWorkspaceReassignmentKeepsOrderAndNoDuplicates() {
        let model = WindowModel()
        let ws1 = WorkspaceDescriptor.ID()
        let ws2 = WorkspaceDescriptor.ID()

        let handle1 = model.upsert(window: makeAXWindowRef(windowId: 101), pid: 77, windowId: 101, workspace: ws1)
        let handle2 = model.upsert(window: makeAXWindowRef(windowId: 102), pid: 77, windowId: 102, workspace: ws1)

        #expect(model.windows(in: ws1).map(\.handle) == [handle1, handle2])

        model.updateWorkspace(for: handle1, workspace: ws2)
        #expect(model.windows(in: ws1).map(\.handle) == [handle2])
        #expect(model.windows(in: ws2).map(\.handle) == [handle1])

        model.updateWorkspace(for: handle1, workspace: ws2)
        #expect(model.windows(in: ws2).map(\.handle) == [handle1])

        model.updateWorkspace(for: handle1, workspace: ws1)
        #expect(model.windows(in: ws1).map(\.handle) == [handle2, handle1])
    }

    @Test func windowModelRemoveMissingMaintainsIndexConsistency() {
        let model = WindowModel()
        let ws1 = WorkspaceDescriptor.ID()
        let ws2 = WorkspaceDescriptor.ID()

        let h1 = model.upsert(window: makeAXWindowRef(windowId: 201), pid: 99, windowId: 201, workspace: ws1)
        let _ = model.upsert(window: makeAXWindowRef(windowId: 202), pid: 99, windowId: 202, workspace: ws1)
        let h3 = model.upsert(window: makeAXWindowRef(windowId: 203), pid: 99, windowId: 203, workspace: ws1)

        model.removeMissing(keys: Set([.init(pid: 99, windowId: 201), .init(pid: 99, windowId: 203)]))
        #expect(model.entry(forWindowId: 202) == nil)
        #expect(model.windows(in: ws1).map(\.windowId) == [201, 203])

        model.updateWorkspace(for: h3, workspace: ws2)
        #expect(model.windows(in: ws1).map(\.handle) == [h1])
        #expect(model.windows(in: ws2).map(\.handle) == [h3])
    }

    @Test func windowModelRemoveMissingRequiresConsecutiveMissesWhenConfigured() {
        let model = WindowModel()
        let ws = WorkspaceDescriptor.ID()

        let _ = model.upsert(window: makeAXWindowRef(windowId: 301), pid: 45, windowId: 301, workspace: ws)
        let _ = model.upsert(window: makeAXWindowRef(windowId: 302), pid: 45, windowId: 302, workspace: ws)

        model.removeMissing(keys: [.init(pid: 45, windowId: 301)], requiredConsecutiveMisses: 2)
        #expect(model.entry(forWindowId: 302) != nil)

        model.removeMissing(keys: [.init(pid: 45, windowId: 301)], requiredConsecutiveMisses: 2)
        #expect(model.entry(forWindowId: 302) == nil)

        let _ = model.upsert(window: makeAXWindowRef(windowId: 303), pid: 45, windowId: 303, workspace: ws)
        model.removeMissing(keys: [], requiredConsecutiveMisses: 2)
        #expect(model.entry(forWindowId: 303) != nil)

        model.removeMissing(keys: [.init(pid: 45, windowId: 303)], requiredConsecutiveMisses: 2)
        model.removeMissing(keys: [], requiredConsecutiveMisses: 2)
        #expect(model.entry(forWindowId: 303) != nil)
    }

    @Test func overviewLayoutHoverAndSelectionOnlyTouchOldAndNew() {
        let ws1 = WorkspaceDescriptor.ID()
        let ws2 = WorkspaceDescriptor.ID()

        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let h3 = makeTestHandle()

        var layout = OverviewLayout()
        layout.workspaceSections = [
            OverviewWorkspaceSection(
                workspaceId: ws1,
                name: "1",
                windows: [
                    makeOverviewWindowItem(handle: h1, workspaceId: ws1, title: "A"),
                    makeOverviewWindowItem(handle: h2, workspaceId: ws1, title: "B")
                ],
                sectionFrame: .zero,
                labelFrame: .zero,
                gridFrame: .zero,
                isActive: true
            ),
            OverviewWorkspaceSection(
                workspaceId: ws2,
                name: "2",
                windows: [makeOverviewWindowItem(handle: h3, workspaceId: ws2, title: "C")],
                sectionFrame: .zero,
                labelFrame: .zero,
                gridFrame: .zero,
                isActive: false
            )
        ]

        layout.setHovered(handle: h1)
        #expect(layout.hoveredWindow()?.handle == h1)

        layout.setHovered(handle: h2, closeButtonHovered: true)
        #expect(layout.hoveredWindow()?.handle == h2)
        #expect(layout.allWindows.first(where: { $0.handle == h1 })?.isHovered == false)
        #expect(layout.allWindows.first(where: { $0.handle == h2 })?.isHovered == true)
        #expect(layout.allWindows.first(where: { $0.handle == h2 })?.closeButtonHovered == true)

        layout.setSelected(handle: h1)
        #expect(layout.selectedWindow()?.handle == h1)
        layout.setSelected(handle: h3)
        #expect(layout.selectedWindow()?.handle == h3)
        #expect(layout.allWindows.first(where: { $0.handle == h1 })?.isSelected == false)
        #expect(layout.allWindows.first(where: { $0.handle == h3 })?.isSelected == true)
    }

    @Test func overviewLayoutFrameUpdateUsesHandleIndex() {
        let ws = WorkspaceDescriptor.ID()
        let h1 = makeTestHandle()
        let h2 = makeTestHandle()
        let frame = CGRect(x: 10, y: 20, width: 320, height: 180)

        var layout = OverviewLayout()
        layout.workspaceSections = [
            OverviewWorkspaceSection(
                workspaceId: ws,
                name: "1",
                windows: [
                    makeOverviewWindowItem(handle: h1, workspaceId: ws, title: "A"),
                    makeOverviewWindowItem(handle: h2, workspaceId: ws, title: "B")
                ],
                sectionFrame: .zero,
                labelFrame: .zero,
                gridFrame: .zero,
                isActive: true
            )
        ]

        layout.updateWindowFrame(handle: h2, frame: frame)
        #expect(layout.allWindows.first(where: { $0.handle == h2 })?.overviewFrame == frame)
        #expect(layout.allWindows.first(where: { $0.handle == h1 })?.overviewFrame == .zero)
    }
}
