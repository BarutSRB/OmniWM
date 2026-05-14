import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import Testing

@Suite(.serialized) @MainActor struct WMControllerReevaluationRegressionTests {
    @Test func automaticReevaluationPreservesTilingForHeuristicFallback() {
        // This test verifies the fix for Issue #306 where popups would cause 
        // tiled windows to float during automatic reevaluation due to heuristic fallbacks.
        
        resetSharedControllerStateForTests()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "com.omniwm.reevaluation.test.\(UUID().uuidString)")!)
        let controller = WMController(settings: settings)
        
        let pid: pid_t = 1234
        let windowId = 5678
        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId)
        let workspaceId = WorkspaceDescriptor.ID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let token = controller.workspaceManager.addWindow(axRef, pid: pid, windowId: windowId, to: workspaceId, mode: .tiling)
        
        guard let entry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Failed to create window entry")
            return
        }
        
        // Scenario: A heuristic fallback decision suggests floating
        let fallbackDecision = WindowDecision(
            disposition: .floating,
            source: .heuristic,
            layoutDecisionKind: .fallbackLayout,
            workspaceName: nil,
            ruleEffects: .none,
            heuristicReasons: [.attributeFetchFailed],
            deferredReason: nil
        )
        
        let resultMode = controller.trackedModeForAutomaticReevaluation(
            decision: fallbackDecision,
            existingEntry: entry,
            context: .automatic
        )
        
        #expect(resultMode == .tiling)
    }

    @Test func automaticReevaluationPreservesTilingForUserRuleFallback() {
        // Verify that even if a user rule is matched, if it's a fallback decision 
        // (e.g. due to attribute fetch failure), we still preserve tiling.
        
        resetSharedControllerStateForTests()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "com.omniwm.reevaluation.test.\(UUID().uuidString)")!)
        let controller = WMController(settings: settings)
        
        let pid: pid_t = 1234
        let windowId = 5678
        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId)
        let workspaceId = WorkspaceDescriptor.ID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let token = controller.workspaceManager.addWindow(axRef, pid: pid, windowId: windowId, to: workspaceId, mode: .tiling)
        
        guard let entry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Failed to create window entry")
            return
        }
        
        // Scenario: User rule matched but it's a fallbackLayout decision
        let fallbackDecision = WindowDecision(
            disposition: .floating,
            source: .userRule(UUID()),
            layoutDecisionKind: .fallbackLayout,
            workspaceName: nil,
            ruleEffects: .none,
            heuristicReasons: [.attributeFetchFailed],
            deferredReason: nil
        )
        
        let resultMode = controller.trackedModeForAutomaticReevaluation(
            decision: fallbackDecision,
            existingEntry: entry,
            context: .automatic
        )
        
        #expect(resultMode == .tiling)
    }

    @Test func automaticReevaluationAcceptsExplicitFloatingRules() {
        // Verify that we don't accidentally block EXPLICIT user rules from flipping to floating.
        
        resetSharedControllerStateForTests()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "com.omniwm.reevaluation.test.\(UUID().uuidString)")!)
        let controller = WMController(settings: settings)
        
        let pid: pid_t = 1234
        let windowId = 5678
        let axRef = AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId)
        let workspaceId = WorkspaceDescriptor.ID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let token = controller.workspaceManager.addWindow(axRef, pid: pid, windowId: windowId, to: workspaceId, mode: .tiling)
        
        guard let entry = controller.workspaceManager.entry(for: token) else {
            Issue.record("Failed to create window entry")
            return
        }
        
        let explicitDecision = WindowDecision(
            disposition: .floating,
            source: .userRule(UUID()),
            layoutDecisionKind: .explicitLayout,
            workspaceName: nil,
            ruleEffects: .none,
            heuristicReasons: [],
            deferredReason: nil
        )
        
        let resultMode = controller.trackedModeForAutomaticReevaluation(
            decision: explicitDecision,
            existingEntry: entry,
            context: .automatic
        )
        
        #expect(resultMode == .floating)
    }
}
