// SPDX-License-Identifier: GPL-2.0-only
import CoreGraphics
import Foundation

@testable import OmniWM

@MainActor
enum MonitorWorkspaceCycleTranscript {
    static let primaryToken = WindowToken(pid: 31_001, windowId: 101)
    static let secondaryToken = WindowToken(pid: 31_001, windowId: 201)

    static let primarySpec = TranscriptMonitorSpec(
        slot: .primary,
        name: "Main",
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
    )
    static let secondarySpec = TranscriptMonitorSpec(
        slot: .secondary(slot: 1),
        name: "Secondary",
        frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080)
    )

    static func make(in context: TranscriptRuntimeContext) -> Transcript {
        let primaryWorkspaceId = context.workspaceId(named: "1")
        let secondaryWorkspaceId = context.workspaceId(named: "2")
        let primaryMonitorId = context.primaryMonitorId
        let secondaryMonitorId = context.monitorIds[1]
        var validatesGraph = TranscriptStepExpectation()
        validatesGraph.perStepInvariants = [.workspaceGraphValidates]

        return Transcript.make(name: "monitor-workspace-cycle") { builder in
            builder
                .event(
                    .windowAdmitted(
                        token: primaryToken,
                        workspaceId: primaryWorkspaceId,
                        monitorId: primaryMonitorId,
                        mode: .tiling,
                        source: .ax
                    ),
                    expectation: validatesGraph
                )
                .event(
                    .windowAdmitted(
                        token: secondaryToken,
                        workspaceId: secondaryWorkspaceId,
                        monitorId: secondaryMonitorId,
                        mode: .tiling,
                        source: .ax
                    ),
                    expectation: validatesGraph
                )
                .command(
                    .layoutMutationAction(.cycleMonitors(source: .command)),
                    expectation: validatesGraph
                )
                .expectFinal(TranscriptExpectations(
                    managedWindowsCount: 2,
                    customAssertions: [.workspaceGraphValidates]
                ))
        }
    }
}
