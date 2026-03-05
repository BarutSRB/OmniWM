import Foundation
import XCTest

@MainActor
final class NiriTxnContractTests: XCTestCase {
    private let legacySymbols = [
        "omni_niri_ctx_apply_navigation",
        "omni_niri_ctx_apply_mutation",
        "omni_niri_ctx_apply_workspace",
        "omni_niri_ctx_export_runtime_state",
        "NiriStateZigRuntimeProjector",
        "NiriStateZigDeltaProjector",
    ]

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func niriSourceDirURL() -> URL {
        repoRootURL().appendingPathComponent("Sources/OmniWM/Core/Layout/Niri")
    }

    private func zigLayoutContextURL() -> URL {
        repoRootURL()
            .appendingPathComponent("zig")
            .appendingPathComponent("omni")
            .appendingPathComponent("layout_context.zig")
    }

    private func niriSwiftFiles() throws -> [URL] {
        let fileManager = FileManager.default
        let baseURL = niriSourceDirURL()
        guard let enumerator = fileManager.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                files.append(fileURL)
            }
        }
        return files
    }

    func testLegacyPerOpRuntimeSymbolsAreNotUsedInSwiftNiriPath() throws {
        let runtimeProjectorPath = niriSourceDirURL().appendingPathComponent("NiriStateZigRuntimeProjector.swift").path
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: runtimeProjectorPath),
            "Legacy runtime projector file should not exist after txn+delta cutover."
        )
        let deltaProjectorPath = niriSourceDirURL().appendingPathComponent("NiriStateZigDeltaProjector.swift").path
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: deltaProjectorPath),
            "Delta projector file should not exist after runtime snapshot cutover."
        )

        for fileURL in try niriSwiftFiles() {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for legacySymbol in legacySymbols where content.contains(legacySymbol) {
                XCTFail("Found legacy symbol '\(legacySymbol)' in \(fileURL.path)")
            }
        }
    }

    func testTxnDeltaSymbolsAreUsedBySwiftKernel() throws {
        let kernelURL = niriSourceDirURL().appendingPathComponent("NiriStateZigKernel.swift")
        let kernelContent = try String(contentsOf: kernelURL, encoding: .utf8)

        XCTAssertTrue(kernelContent.contains("omni_niri_runtime_apply_command"))
        XCTAssertTrue(kernelContent.contains("omni_niri_runtime_seed"))
        XCTAssertTrue(kernelContent.contains("omni_niri_runtime_snapshot"))
        XCTAssertTrue(kernelContent.contains("omni_niri_ctx_export_delta"))
    }

    func testTxnDispatcherHasNoLegacyBridgeMarkersInZig() throws {
        let zigContent = try String(contentsOf: zigLayoutContextURL(), encoding: .utf8)

        XCTAssertFalse(zigContent.contains("legacy_request"))
        XCTAssertFalse(zigContent.contains("legacy_result"))
        XCTAssertFalse(zigContent.contains("buildNavigationApplyRequestFromTxn"))
        XCTAssertFalse(zigContent.contains("buildMutationApplyRequestFromTxn"))
        XCTAssertFalse(zigContent.contains("buildWorkspaceApplyRequestFromTxn"))
        XCTAssertFalse(zigContent.contains("omni_niri_ctx_apply_navigation_impl"))
        XCTAssertFalse(zigContent.contains("omni_niri_ctx_apply_mutation_impl"))
        XCTAssertFalse(zigContent.contains("omni_niri_ctx_apply_workspace_impl"))
    }

    func testNiriOpsAndNavigationHaveNoSwiftIndexLookupCommandPath() throws {
        let fileNames = [
            "NiriLayoutEngine+ColumnOps.swift",
            "NiriLayoutEngine+WindowOps.swift",
            "NiriLayoutEngine+WorkspaceOps.swift",
            "NiriLayoutEngine+Windows.swift",
            "NiriNavigation.swift",
        ]

        for fileName in fileNames {
            let fileURL = niriSourceDirURL().appendingPathComponent(fileName)
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertFalse(content.contains("makeIndexLookup("), "Found legacy index lookup in \(fileName)")
            XCTAssertFalse(content.contains("makeSelectionContext("), "Found legacy selection context lookup in \(fileName)")
            XCTAssertFalse(content.contains("mutationNodeTarget("), "Found legacy mutation target lookup in \(fileName)")
            XCTAssertFalse(content.contains("IndexLookup"), "Found legacy IndexLookup type usage in \(fileName)")
        }
    }

    func testSwiftRenderPathHasNoLegacyLayoutFallback() throws {
        let kernelURL = niriSourceDirURL().appendingPathComponent("NiriLayoutZigKernel.swift")
        let kernelContent = try String(contentsOf: kernelURL, encoding: .utf8)

        XCTAssertTrue(kernelContent.contains("omni_niri_runtime_render("))
        XCTAssertFalse(kernelContent.contains("omni_niri_layout_pass_v3("))
        XCTAssertTrue(kernelContent.contains("runtimeRenderStateMismatch"))
        XCTAssertTrue(kernelContent.contains("OMNI_ERR_OUT_OF_RANGE"))
        XCTAssertFalse(kernelContent.contains("seedRuntimeState("))
        XCTAssertFalse(kernelContent.contains("reseed_rc="))
        XCTAssertFalse(kernelContent.contains("retry_rc="))
    }

    func testPhase3OperationReadPathsDoNotUseNodeCastLookups() throws {
        let operationFiles = [
            "NiriLayoutEngine+Sizing.swift",
            "NiriLayoutEngine+TabbedMode.swift",
            "NiriLayoutEngine+InteractiveResize.swift",
            "NiriLayoutEngine+InteractiveMove.swift",
            "NiriLayoutEngine+ColumnOps.swift",
            "NiriLayoutEngine+WindowOps.swift",
            "NiriLayoutEngine+WorkspaceOps.swift",
            "NiriLayoutEngine+Windows.swift",
            "NiriNavigation.swift",
            "NiriRuntimeBoundary.swift",
        ]

        for fileName in operationFiles {
            let fileURL = niriSourceDirURL().appendingPathComponent(fileName)
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertFalse(
                content.contains("as? NiriWindow"),
                "Phase 3 operation reads must not use NiriWindow cast lookup in \(fileName)"
            )
            XCTAssertFalse(
                content.contains("as? NiriContainer"),
                "Phase 3 operation reads must not use NiriContainer cast lookup in \(fileName)"
            )
        }
    }

    func testPhase3NavigationReadPathUsesRuntimeViewSelection() throws {
        let navigationURL = niriSourceDirURL().appendingPathComponent("NiriNavigation.swift")
        let navigationContent = try String(contentsOf: navigationURL, encoding: .utf8)

        XCTAssertTrue(navigationContent.contains("runtimeSelectionAnchor("))
        XCTAssertTrue(navigationContent.contains("resolveWorkspaceNavigationTargetNode("))
        XCTAssertFalse(navigationContent.contains("makeSnapshot(columns: columns(in: workspaceId))"))
    }

    func testPhase3LayoutInteractionIndexUsesRuntimeView() throws {
        let layoutURL = niriSourceDirURL().appendingPathComponent("NiriLayout.swift")
        let layoutContent = try String(contentsOf: layoutURL, encoding: .utf8)

        XCTAssertTrue(layoutContent.contains("runtimeWorkspaceView(for: workspaceId)"))
        XCTAssertTrue(layoutContent.contains("makeInteractionIndex("))
        XCTAssertTrue(layoutContent.contains("view: runtimeView"))
    }

    func testPhase1RuntimeBoundaryTypesAndStoreDispatchExist() throws {
        let boundaryURL = niriSourceDirURL().appendingPathComponent("NiriRuntimeBoundary.swift")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: boundaryURL.path),
            "Phase 1 runtime boundary file must exist."
        )
        let boundaryContent = try String(contentsOf: boundaryURL, encoding: .utf8)
        XCTAssertTrue(boundaryContent.contains("enum NiriRuntimeCommand"))
        XCTAssertTrue(boundaryContent.contains("struct NiriRuntimeWorkspaceView"))
        XCTAssertTrue(boundaryContent.contains("final class NiriRuntimeWorkspaceStore"))
        XCTAssertTrue(boundaryContent.contains("func runtimeStore("))

        let operationFiles = [
            "NiriLayoutEngine+ColumnOps.swift",
            "NiriLayoutEngine+WindowOps.swift",
            "NiriLayoutEngine+WorkspaceOps.swift",
            "NiriLayoutEngine+Windows.swift",
            "NiriNavigation.swift",
        ]
        for fileName in operationFiles {
            let fileURL = niriSourceDirURL().appendingPathComponent(fileName)
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertTrue(
                content.contains("runtimeStore(") || content.contains("executeNavigation(") || content.contains("executeLifecycle("),
                "Expected Phase 1 runtime boundary store usage in \(fileName)"
            )
        }

        let commandFiles = [
            "NiriLayoutEngine+ColumnOps.swift",
            "NiriLayoutEngine+WindowOps.swift",
            "NiriLayoutEngine+WorkspaceOps.swift",
            "NiriLayoutEngine+Windows.swift",
        ]
        for fileName in commandFiles {
            let fileURL = niriSourceDirURL().appendingPathComponent(fileName)
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertFalse(
                content.contains("NiriStateZigKernel.MutationRequest("),
                "Expected typed runtime command dispatch (no direct mutation request builders) in \(fileName)"
            )
            XCTAssertFalse(
                content.contains("NiriStateZigKernel.WorkspaceRequest("),
                "Expected typed runtime command dispatch (no direct workspace request builders) in \(fileName)"
            )
        }
    }

    func testPhase2OperationalMutationPathsDoNotUseSyncRuntimeReseed() throws {
        let operationFiles = [
            "NiriLayoutEngine+Sizing.swift",
            "NiriLayoutEngine+TabbedMode.swift",
            "NiriLayoutEngine+InteractiveResize.swift",
            "NiriLayoutEngine+ColumnOps.swift",
            "NiriLayoutEngine+WindowOps.swift",
            "NiriLayoutEngine+WorkspaceOps.swift",
            "NiriLayoutEngine+Windows.swift",
        ]

        for fileName in operationFiles {
            let fileURL = niriSourceDirURL().appendingPathComponent(fileName)
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertFalse(
                content.contains("syncRuntimeStateNow("),
                "Phase 2 operation paths must not call syncRuntimeStateNow in \(fileName)"
            )
        }
    }

    func testPhase2SizingAndTabbedMutationPathsUseRuntimeCommands() throws {
        let sizingURL = niriSourceDirURL().appendingPathComponent("NiriLayoutEngine+Sizing.swift")
        let sizingContent = try String(contentsOf: sizingURL, encoding: .utf8)
        XCTAssertTrue(sizingContent.contains(".setWindowSizingMode("))
        XCTAssertTrue(sizingContent.contains(".setColumnWidth("))
        XCTAssertTrue(sizingContent.contains(".setWindowHeight("))
        XCTAssertFalse(sizingContent.contains("window.height ="))
        XCTAssertFalse(sizingContent.contains("window.sizingMode = mode"))
        XCTAssertFalse(sizingContent.contains("column.width ="))
        XCTAssertFalse(sizingContent.contains("column.isFullWidth ="))
        XCTAssertFalse(sizingContent.contains("column.savedWidth ="))

        let tabbedURL = niriSourceDirURL().appendingPathComponent("NiriLayoutEngine+TabbedMode.swift")
        let tabbedContent = try String(contentsOf: tabbedURL, encoding: .utf8)
        XCTAssertTrue(tabbedContent.contains(".setColumnDisplay("))
        XCTAssertTrue(tabbedContent.contains(".setColumnActiveTile("))
        XCTAssertFalse(tabbedContent.contains("column.displayMode = mode"))
        XCTAssertFalse(tabbedContent.contains("column.displayMode = ."))
        XCTAssertFalse(tabbedContent.contains("column.setActiveTileIdx("))
    }
}
