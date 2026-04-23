// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing

@testable import OmniWM

@Suite struct WorkspacesSettingsTabTests {
    @Test func addPolicyProposesWorkspace10AfterNineSlotsAreUsed() {
        let configurations = (1...9).map { WorkspaceConfiguration(name: String($0)) }

        #expect(
            WorkspaceConfigurationAddPolicy.nextAvailableWorkspaceName(in: configurations) == "10"
        )
    }

    @Test func addPolicyReusesNumericGapsBeforeGrowingPastNine() {
        let configurations = [
            WorkspaceConfiguration(name: "1"),
            WorkspaceConfiguration(name: "3"),
            WorkspaceConfiguration(name: "10")
        ]

        #expect(
            WorkspaceConfigurationAddPolicy.nextAvailableWorkspaceName(in: configurations) == "2"
        )
    }

    @Test func workspaceSettingsCopyMentionsTenPlusInsteadOfNineWorkspaceCap() {
        #expect(WorkspaceConfigurationAddPolicy.addButtonHelp.contains("9") == false)
        #expect(WorkspaceConfigurationAddPolicy.footerText.contains("at most 9") == false)
        #expect(WorkspaceConfigurationAddPolicy.footerText.contains("10+") == true)
    }

    @Test @MainActor func floatingOnlyWorkspaceBlocksDeletion() throws {
        let controller = makeLayoutPlanTestController()
        let settings = controller.settings
        guard let workspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false),
              let config = settings.workspaceConfigurations.first(where: { $0.name == "2" })
        else {
            Issue.record("Missing workspace settings fixture")
            return
        }

        _ = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1101),
            pid: 8101,
            windowId: 1101,
            to: workspaceId,
            mode: .floating
        )

        #expect(
            WorkspaceConfigurationDeletePolicy.canDelete(
                config,
                settings: settings,
                workspaceManager: controller.workspaceManager
            ) == false
        )
        #expect(
            WorkspaceConfigurationDeletePolicy.deleteHelp(
                config,
                settings: settings,
                workspaceManager: controller.workspaceManager
            ) == "Move or close all windows in this workspace before deleting it"
        )
    }

    @Test @MainActor func tiledWorkspaceStillBlocksDeletion() throws {
        let controller = makeLayoutPlanTestController()
        let settings = controller.settings
        guard let workspaceId = controller.workspaceManager.workspaceId(for: "2", createIfMissing: false),
              let config = settings.workspaceConfigurations.first(where: { $0.name == "2" })
        else {
            Issue.record("Missing workspace settings fixture")
            return
        }

        _ = controller.workspaceManager.addWindow(
            makeLayoutPlanTestWindow(windowId: 1102),
            pid: 8102,
            windowId: 1102,
            to: workspaceId,
            mode: .tiling
        )

        #expect(
            WorkspaceConfigurationDeletePolicy.canDelete(
                config,
                settings: settings,
                workspaceManager: controller.workspaceManager
            ) == false
        )
        #expect(
            WorkspaceConfigurationDeletePolicy.deleteHelp(
                config,
                settings: settings,
                workspaceManager: controller.workspaceManager
            ) == "Move or close all windows in this workspace before deleting it"
        )
    }
}
