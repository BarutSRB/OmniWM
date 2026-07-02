// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

@MainActor
enum RuntimeDiagnosticsReport {
    static func build(_ controller: WMController, traceLimit: Int) -> String {
        [
            systemSection(controller),
            section("Active Issues", issuesSection(controller)),
            section("Private API Capability", PrivateAPIHealthDiagnostics.snapshot().formatted()),
            section("Recent Errors", LogErrorTap.shared.dump()),
            monitorSection(),
            section("Space Topology", controller.workspaceManager.spaceTopology.debugSummary),
            focusedWindowSection(controller),
            section("Input / Hotkey Health", InputDiagnostics.inputHealth(controller).formatted()),
            section("Owned Windows / Surface", InputDiagnostics.ownedSurfaces(controller).formatted()),
            section("Interaction Monitor Writes", InteractionMonitorWriteRecorder.shared.dump()),
            section("Reconcile Snapshot", controller.workspaceManager.reconcileSnapshotDump()),
            section("Reconcile Trace", controller.workspaceManager.reconcileTraceDump(limit: traceLimit)),
            section("Invariant Violations", controller.workspaceManager.invariantViolationCountsDump()),
            section("AX Frame State", controller.axManager.frameStateDump()),
            section("Hidden Window Physical State", hiddenWindowPhysicalSection(controller)),
            section("Recent AX Notifications", RawAXNotificationTrace.shared.recentDump()),
            section("Layout Build Metrics", controller.layoutRefreshController.layoutBuildMetricsDump()),
            section("Create-Focus Trace", controller.axEventHandler.createFocusTraceDump()),
            section("Managed Replacement Trace", controller.axEventHandler.managedReplacementTraceDump()),
            settingsSection(controller)
        ]
        .joined(separator: "\n\n")
    }

    private static func hiddenWindowPhysicalSection(_ controller: WMController) -> String {
        let monitorFrames = controller.workspaceManager.monitors.map(\.frame)
        var lines: [String] = []
        for entry in controller.workspaceManager.allEntries() {
            guard let hiddenState = controller.workspaceManager.hiddenState(for: entry.token) else { continue }
            let placement = switch hiddenState.reason {
            case let .layoutTransient(side): "side=\(side)"
            case .workspaceInactive: "inactive"
            case .scratchpad: "scratchpad"
            }
            guard let windowId = UInt32(exactly: entry.windowId),
                  let bounds = SkyLight.shared.getWindowBounds(windowId)
            else {
                lines.append("win=\(entry.windowId) \(placement) physical=unknown")
                continue
            }
            let frame = ScreenCoordinateSpace.toAppKit(rect: bounds)
            let overlap = monitorFrames
                .map { $0.intersection(frame) }
                .filter { !$0.isNull && !$0.isEmpty }
                .max { $0.width * $0.height < $1.width * $1.height }
            let overlapText = overlap.map { "\(Int($0.width))x\(Int($0.height))" } ?? "0x0"
            let bleeding = (overlap?.width ?? 0) > 16 && (overlap?.height ?? 0) > 16
            lines.append(
                "win=\(entry.windowId) \(placement) physical=\(TraceFormat.rect(frame))"
                    + " onscreen=\(overlapText)\(bleeding ? " BLEED" : "")"
            )
        }
        let pending = controller.axManager.pendingParkWindowIds.sorted()
        lines.append("pendingParks=\(pending.isEmpty ? "none" : pending.map(String.init).joined(separator: ","))")
        return lines.joined(separator: "\n")
    }

    private static func section(_ title: String, _ body: String) -> String {
        "== \(title) ==\n\(body)"
    }

    private static func issuesSection(_ controller: WMController) -> String {
        let issues = DiagnosticsIssueAggregator.applicableIssues(controller: controller)
        guard !issues.isEmpty else { return "none" }
        return issues
            .map { issue in
                let label = issue.severity == .critical ? "CRITICAL" : "WARNING"
                return "[\(label)] \(issue.title) — \(issue.message)"
            }
            .joined(separator: "\n")
    }

    private static func systemSection(_ controller: WMController) -> String {
        let lines = [
            "generatedAt=\(Date().ISO8601Format())",
            "appVersion=\(OmniWMBuildInfo.version)",
            "build=\(OmniWMBuildInfo.build)",
            "gitHash=\(OmniWMBuildInfo.gitHash)",
            "os=\(ProcessInfo.processInfo.operatingSystemVersionString)",
            "accessibilityGranted=\(controller.accessibilityPermissionGranted)",
            "enabled=\(controller.isEnabled)"
        ]
        return section("OmniWM Diagnostics", lines.joined(separator: "\n"))
    }

    private static func monitorSection() -> String {
        let monitors = Monitor.current()
        guard !monitors.isEmpty else { return section("Monitors", "none") }
        let body = monitors
            .map { "id=\($0.id) name=\($0.name) frame=\(format($0.frame)) visible=\(format($0.visibleFrame))" }
            .joined(separator: "\n")
        return section("Monitors", body)
    }

    private static func focusedWindowSection(_ controller: WMController) -> String {
        section("Focused Window Decision", controller.focusedWindowDecisionDebugSnapshot()?.formattedDump() ?? "none")
    }

    private static func settingsSection(_ controller: WMController) -> String {
        let body: String
        do {
            let encoded = try SettingsTOMLCodec.encode(controller.settings.toExport())
            body = String(bytes: encoded, encoding: .utf8) ?? ""
        } catch {
            body = "settings encode failed: \(error.localizedDescription)"
        }
        return section("Settings (TOML)", body)
    }

    private static func format(_ rect: CGRect) -> String {
        "x=\(Int(rect.minX.rounded())) y=\(Int(rect.minY.rounded())) w=\(Int(rect.width.rounded())) h=\(Int(rect.height.rounded()))"
    }
}
