// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class NiriAdmissionRestoreStateTests: XCTestCase {
    func testHintOnlyReevaluationUpdatesBeforeFirstClaimWithoutLayoutInvalidation() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        controller.niriLayoutHandler.enableNiriLayout()

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(801), windowId: 91),
            pid: 801,
            windowId: 91,
            to: workspaceId,
            admissionHints: ManagedWindowAdmissionHints(initialNiriColumnWidth: 0.5)
        )
        let beforeUpdate = controller.workspaceManager.worldSeq
        let constraints = WindowSizeConstraints(
            minSize: CGSize(width: 200, height: 100),
            maxSize: CGSize(width: 1200, height: 900),
            isFixed: false
        )
        controller.workspaceManager.setCachedConstraints(constraints, for: token)

        XCTAssertTrue(
            controller.workspaceManager.updateAdmissionHints(
                ManagedWindowAdmissionHints(initialNiriColumnWidth: 0.75),
                for: token
            )
        )
        XCTAssertEqual(
            controller.workspaceManager.admissionHints(for: token)?.initialNiriColumnWidth,
            0.75
        )
        XCTAssertTrue(controller.workspaceManager.isSeqEpochCurrent(beforeUpdate, domains: .layout))
        XCTAssertEqual(
            controller.workspaceManager.cachedConstraints(for: token, maxAge: .greatestFiniteMagnitude),
            constraints
        )

        let engine = try XCTUnwrap(controller.niriEngine)
        controller.workspaceManager.withEngineMutationScope {
            _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        }

        XCTAssertFalse(
            controller.workspaceManager.updateAdmissionHints(
                ManagedWindowAdmissionHints(initialNiriColumnWidth: 1.0),
                for: token
            )
        )
        XCTAssertEqual(
            controller.workspaceManager.admissionHints(for: token)?.initialNiriColumnWidth,
            0.75
        )
    }

    func testFloatingCapturePersistsAndSuccessfulReattachClearsDetachedWidth() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let workspaceName = try XCTUnwrap(controller.workspaceManager.descriptor(for: workspaceId)?.name)
        controller.niriLayoutHandler.enableNiriLayout()

        let token = WindowToken(pid: 802, windowId: 92)
        let metadata = ManagedReplacementMetadata(
            bundleId: "com.example.restore-width",
            workspaceId: workspaceId,
            mode: .tiling,
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            title: "Document",
            windowLevel: 0,
            parentWindowId: nil,
            frame: CGRect(x: 10, y: 20, width: 700, height: 500)
        )
        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(token.pid), windowId: token.windowId),
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId,
            admissionHints: ManagedWindowAdmissionHints(initialNiriColumnWidth: 0.5),
            managedReplacementMetadata: metadata
        )

        let expected = NiriColumnWidthState(
            width: .proportion(0.72),
            presetWidthIndex: nil,
            isFullWidth: false,
            savedWidth: .fixed(640),
            hasManualSingleWindowWidthOverride: true
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        controller.workspaceManager.withEngineMutationScope {
            let node = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
            guard let column = engine.column(of: node) else {
                XCTFail("Expected Niri column")
                return
            }
            Self.apply(expected, to: column)
        }

        XCTAssertTrue(controller.workspaceManager.setWindowMode(.floating, for: token))
        XCTAssertNil(engine.findNode(for: token, in: workspaceId))
        XCTAssertEqual(
            controller.workspaceManager.restoreIntent(for: token)?.detachedNiriColumnWidthState,
            expected
        )

        controller.workspaceManager.flushPersistedWindowRestoreCatalogNow()
        let persistedEntry = try XCTUnwrap(
            controller.settings.loadPersistedWindowRestoreCatalog().entries.first {
                $0.restoreIntent.workspaceName == workspaceName
            }
        )
        XCTAssertEqual(persistedEntry.restoreIntent.detachedNiriColumnWidthState, expected)

        XCTAssertTrue(controller.workspaceManager.setWindowMode(.tiling, for: token))
        let placements = controller.workspaceManager.withBatchedLayoutBuild {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        }.first?.niriRestorePlacements ?? [:]
        XCTAssertEqual(engine.columnWidthState(for: token, in: workspaceId), expected)
        let placement = try XCTUnwrap(placements[token])
        controller.workspaceManager.setNiriRestorePlacements([token: placement])

        XCTAssertNil(
            controller.workspaceManager.restoreIntent(for: token)?.detachedNiriColumnWidthState
        )
        XCTAssertEqual(
            controller.workspaceManager.restoreIntent(for: token)?.niriPlacement,
            placement
        )

        _ = controller.workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)
        controller.workspaceManager.flushPersistedWindowRestoreCatalogNow()
        XCTAssertTrue(controller.settings.loadPersistedWindowRestoreCatalog().entries.isEmpty)
    }

    func testEngineReplacementCapturesLiveWidth() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        controller.niriLayoutHandler.enableNiriLayout()

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(803), windowId: 93),
            pid: 803,
            windowId: 93,
            to: workspaceId
        )
        let expected = NiriColumnWidthState(
            width: .fixed(730),
            presetWidthIndex: 2,
            isFullWidth: true,
            savedWidth: .proportion(0.6),
            hasManualSingleWindowWidthOverride: false
        )
        let oldEngine = try XCTUnwrap(controller.niriEngine)
        controller.workspaceManager.withEngineMutationScope {
            let node = oldEngine.addWindow(token: token, to: workspaceId, afterSelection: nil)
            guard let column = oldEngine.column(of: node) else {
                XCTFail("Expected Niri column")
                return
            }
            Self.apply(expected, to: column)
        }

        controller.niriLayoutHandler.enableNiriLayout()

        XCTAssertEqual(
            controller.workspaceManager.restoreIntent(for: token)?.detachedNiriColumnWidthState,
            expected
        )
        XCTAssertNil(controller.niriEngine?.findNode(for: token, in: workspaceId))

        let placements = controller.workspaceManager.withBatchedLayoutBuild {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        }.first?.niriRestorePlacements ?? [:]
        XCTAssertEqual(controller.niriEngine?.columnWidthState(for: token, in: workspaceId), expected)
        controller.workspaceManager.setNiriRestorePlacements(placements)
        XCTAssertNil(
            controller.workspaceManager.restoreIntent(for: token)?.detachedNiriColumnWidthState
        )
    }

    func testMatchedPersistedRestoreHydratesDetachedWidth() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMTests-\(UUID().uuidString)", isDirectory: true)
        let token = WindowToken(pid: 804, windowId: 94)
        let placeholderWorkspaceId = WorkspaceDescriptor.ID()
        let metadata = ManagedReplacementMetadata(
            bundleId: "com.example.hydrated-width",
            workspaceId: placeholderWorkspaceId,
            mode: .tiling,
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            title: "Hydrate",
            windowLevel: 0,
            parentWindowId: nil,
            frame: nil
        )
        let expected = NiriColumnWidthState(
            width: .proportion(0.82),
            presetWidthIndex: 1,
            isFullWidth: false,
            savedWidth: nil,
            hasManualSingleWindowWidthOverride: true
        )
        let persistedEntry = PersistedWindowRestoreEntry(
            key: try XCTUnwrap(PersistedWindowRestoreKey(metadata: metadata)),
            identity: try XCTUnwrap(PersistedWindowRestoreIdentity(token: token, metadata: metadata)),
            restoreIntent: PersistedRestoreIntent(
                workspaceName: "1",
                topologyProfile: TopologyProfile(sortedMonitors: []),
                preferredMonitor: nil,
                floatingFrame: nil,
                normalizedFloatingOrigin: nil,
                restoreToFloating: false,
                rescueEligible: false,
                detachedNiriColumnWidthState: expected
            )
        )
        let runtimeState = RuntimeStateStore(
            directory: root.appendingPathComponent("state", isDirectory: true),
            deferSaves: false
        )
        runtimeState.windowRestoreCatalog = PersistedWindowRestoreCatalog(entries: [persistedEntry])
        let reloadedRuntimeState = RuntimeStateStore(
            directory: root.appendingPathComponent("state", isDirectory: true),
            deferSaves: false
        )
        XCTAssertEqual(
            reloadedRuntimeState.windowRestoreCatalog?.entries.first?.restoreIntent.detachedNiriColumnWidthState,
            expected
        )
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: reloadedRuntimeState,
            autosaveEnabled: false
        )
        let controller = Self.controller(settings: settings)
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        var liveMetadata = metadata
        liveMetadata.workspaceId = workspaceId

        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(token.pid), windowId: token.windowId),
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId,
            managedReplacementMetadata: liveMetadata
        )

        XCTAssertEqual(
            controller.workspaceManager.restoreIntent(for: token)?.detachedNiriColumnWidthState,
            expected
        )
        XCTAssertEqual(controller.workspaceManager.workspace(for: token), workspaceId)
    }

    func testNiriSourceMoveKeepsLiveWidthOverAdmissionHint() throws {
        let controller = Self.controller()
        let sourceWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let targetWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        controller.niriLayoutHandler.enableNiriLayout()

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(805), windowId: 95),
            pid: 805,
            windowId: 95,
            to: sourceWorkspaceId,
            admissionHints: ManagedWindowAdmissionHints(initialNiriColumnWidth: 0.5),
            managedReplacementMetadata: ManagedReplacementMetadata(
                bundleId: "com.example.source-move-width",
                workspaceId: sourceWorkspaceId,
                mode: .tiling,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: "Source Move",
                windowLevel: 0,
                parentWindowId: nil,
                frame: nil
            )
        )
        let expected = NiriColumnWidthState(
            width: .proportion(0.88),
            presetWidthIndex: nil,
            isFullWidth: false,
            savedWidth: nil,
            hasManualSingleWindowWidthOverride: false
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        var node: NiriWindow?
        controller.workspaceManager.withEngineMutationScope {
            let addedNode = engine.addWindow(token: token, to: sourceWorkspaceId, afterSelection: nil)
            node = addedNode
            guard let column = engine.column(of: addedNode) else {
                XCTFail("Expected Niri column")
                return
            }
            Self.apply(expected, to: column)
        }

        let result = controller.workspaceManager.withBatchedWorkspaceMove(
            sourceWorkspaceId: sourceWorkspaceId,
            targetWorkspaceId: targetWorkspaceId
        ) { sourceState, targetState in
            guard let node,
                  let moveResult = engine.moveWindowToWorkspace(
                      node,
                      from: sourceWorkspaceId,
                      to: targetWorkspaceId,
                      sourceState: &sourceState,
                      targetState: &targetState
                  )
            else {
                return nil
            }
            return (moveResult, [token])
        }

        XCTAssertNotNil(result)
        XCTAssertEqual(engine.columnWidthState(for: token, in: targetWorkspaceId), expected)
        XCTAssertEqual(
            controller.workspaceManager.restoreIntent(for: token)?.detachedNiriColumnWidthState,
            expected
        )
        XCTAssertEqual(
            controller.workspaceManager.admissionHints(for: token)?.initialNiriColumnWidth,
            0.5
        )

        controller.workspaceManager.flushPersistedWindowRestoreCatalogNow()
        let persisted = try XCTUnwrap(
            controller.settings.loadPersistedWindowRestoreCatalog().entries.first {
                $0.identity?.windowId == token.windowId
            }
        )
        XCTAssertEqual(persisted.restoreIntent.detachedNiriColumnWidthState, expected)

        let placements = controller.workspaceManager.withBatchedLayoutBuild {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [targetWorkspaceId])
        }.first?.niriRestorePlacements ?? [:]
        controller.workspaceManager.setNiriRestorePlacements(placements)
        XCTAssertNil(controller.workspaceManager.restoreIntent(for: token)?.detachedNiriColumnWidthState)
    }

    func testNiriToDwindleMoveCapturesLiveWidthBeforeDirectRemoval() throws {
        let controller = Self.controller()
        let sourceWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let targetWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        var configurations = controller.settings.workspaceConfigurations
        let targetIndex = try XCTUnwrap(configurations.firstIndex { $0.name == "2" })
        configurations[targetIndex] = configurations[targetIndex].with(layoutType: .dwindle)
        controller.settings.workspaceConfigurations = configurations
        controller.niriLayoutHandler.enableNiriLayout()

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(806), windowId: 96),
            pid: 806,
            windowId: 96,
            to: sourceWorkspaceId,
            admissionHints: ManagedWindowAdmissionHints(initialNiriColumnWidth: 0.4)
        )
        let expected = NiriColumnWidthState(
            width: .fixed(680),
            presetWidthIndex: nil,
            isFullWidth: false,
            savedWidth: .proportion(0.7),
            hasManualSingleWindowWidthOverride: true
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        controller.workspaceManager.withEngineMutationScope {
            let node = engine.addWindow(token: token, to: sourceWorkspaceId, afterSelection: nil)
            guard let column = engine.column(of: node) else {
                XCTFail("Expected Niri column")
                return
            }
            Self.apply(expected, to: column)
        }

        XCTAssertTrue(
            controller.workspaceNavigationHandler.moveWindow(
                handle: WindowHandle(id: token),
                toWorkspaceId: targetWorkspaceId
            )
        )

        XCTAssertNil(engine.findNode(for: token, in: sourceWorkspaceId))
        XCTAssertEqual(controller.workspaceManager.workspace(for: token), targetWorkspaceId)
        XCTAssertEqual(
            controller.workspaceManager.restoreIntent(for: token)?.detachedNiriColumnWidthState,
            expected
        )
    }

    private static func controller(settings: SettingsStore? = nil) -> WMController {
        if let settings {
            return configuredController(settings: settings)
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        return configuredController(settings: settings)
    }

    private static func configuredController(settings: SettingsStore) -> WMController {
        WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
    }

    private static func apply(_ state: NiriColumnWidthState, to column: NiriContainer) {
        column.width = state.width
        column.presetWidthIdx = state.presetWidthIndex
        column.isFullWidth = state.isFullWidth
        column.savedWidth = state.savedWidth
        column.hasManualSingleWindowWidthOverride = state.hasManualSingleWindowWidthOverride
    }
}
