// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Carbon
import Foundation
import QuartzCore
import ScreenCaptureKit

enum OverviewHotkeyDisposition: Equatable {
    case inactive
    case handled
    case blocked
}

enum OverviewPhysicalHotkeyAction: Equatable {
    case dismissSelection
    case closeSelection
}

@MainActor
struct OverviewEnvironment {
    var frontmostApplicationPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var currentProcessID: () -> pid_t = { getpid() }
    var activateOmniWM: () -> Void = { NSApp.activate(ignoringOtherApps: true) }
    var activateApplication: (pid_t) -> Void = { pid in
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    }

    var addLocalEventMonitor: (
        NSEvent.EventTypeMask,
        @escaping (NSEvent) -> NSEvent?
    ) -> Any? = { mask, handler in
        NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
    }

    var removeEventMonitor: (Any) -> Void = { monitor in
        NSEvent.removeMonitor(monitor)
    }

    var notificationCenter: NotificationCenter = .default
    var selectionDismissDelayNanoseconds: UInt64 = 50_000_000
    var schedulePostCloseHandoff: (@escaping @MainActor () -> Void) -> Void = { handoff in
        Task { @MainActor in
            await Task.yield()
            handoff()
        }
    }

    var windowTitle: (WindowState) -> String? = { entry in
        AXWindowService.titlePreferFast(windowId: UInt32(entry.windowId))
    }

    var windowFrame: (WindowState) -> CGRect? = { entry in
        AXWindowService.framePreferFast(entry.axRef)
    }

    var onThumbnailCaptureStarted: () -> Void = {}
    var onCachedProjectionRefreshed: (Set<WorkspaceDescriptor.ID>) -> Void = { _ in }
}

struct DwindleOverviewWorkspaceProjection {
    let eligibleTokens: Set<WindowToken>
    let inactiveTokens: Set<WindowToken>
    let frames: [WindowToken: CGRect]
    let groupCountByToken: [WindowToken: Int]

    init(
        engine: DwindleLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        eligibleTokens: Set<WindowToken>
    ) {
        self.eligibleTokens = eligibleTokens

        var inactiveTokens = engine.inactiveGroupTokens(in: workspaceId)
        var frames = engine.currentFrames(in: workspaceId)

        var groupCounts: [WindowToken: Int] = [:]
        for snapshot in engine.groupedTileSnapshots(in: workspaceId) {
            let eligibleMembers = snapshot.members.filter { eligibleTokens.contains($0.token) }
            let representative = eligibleMembers.first { $0.token == snapshot.activeToken }
                ?? eligibleMembers.first
            let frame = frames[snapshot.activeToken] ?? snapshot.contentFrame ?? snapshot.tileFrame

            inactiveTokens.formUnion(snapshot.members.map(\.token))
            for member in snapshot.members {
                frames.removeValue(forKey: member.token)
            }

            guard let representative else { continue }
            inactiveTokens.remove(representative.token)
            if let frame {
                frames[representative.token] = frame
            }
            if eligibleMembers.count > 1 {
                groupCounts[representative.token] = eligibleMembers.count
            }
        }
        self.inactiveTokens = inactiveTokens
        self.frames = frames
        groupCountByToken = groupCounts
    }

    func includes(_ token: WindowToken) -> Bool {
        eligibleTokens.contains(token) && !inactiveTokens.contains(token)
    }
}

extension OverviewController {
    enum OverviewDismissReason {
        case cancel
        case selection
        case externalDeactivation

        var shouldRestorePreviousApplication: Bool {
            switch self {
            case .cancel:
                true
            case .selection,
                 .externalDeactivation:
                false
            }
        }
    }
}
