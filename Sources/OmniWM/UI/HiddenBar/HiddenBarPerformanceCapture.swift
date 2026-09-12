// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

extension HiddenBarController {
    enum MenuGuardTerminalReason: Equatable, Sendable {
        case concealed
        case noRevealedItems
        case unknownStateLimit
        case watchdog
        case cancelled
        case superseded
    }

    struct PerformanceSnapshot: Equatable, Sendable {
        let refreshEvents: UInt64
        let menuGuardQueries: UInt64
        let reconcealTasksStarted: UInt64
        let reconcealTasksCancelled: UInt64
        let menuGuardDeferrals: UInt64
        let maximumConsecutiveDeferrals: Int
        let terminalReason: MenuGuardTerminalReason?
    }
}

@MainActor
final class HiddenBarPerformanceCapture {
    private struct Counters {
        var refreshEvents: UInt64 = 0
        var menuGuardQueries: UInt64 = 0
        var reconcealTasksStarted: UInt64 = 0
        var reconcealTasksCancelled: UInt64 = 0
        var menuGuardDeferrals: UInt64 = 0
        var maximumConsecutiveDeferrals = 0
        var terminalReason: HiddenBarController.MenuGuardTerminalReason?

        var snapshot: HiddenBarController.PerformanceSnapshot {
            HiddenBarController.PerformanceSnapshot(
                refreshEvents: refreshEvents,
                menuGuardQueries: menuGuardQueries,
                reconcealTasksStarted: reconcealTasksStarted,
                reconcealTasksCancelled: reconcealTasksCancelled,
                menuGuardDeferrals: menuGuardDeferrals,
                maximumConsecutiveDeferrals: maximumConsecutiveDeferrals,
                terminalReason: terminalReason
            )
        }
    }

    private var counters: Counters?

    func begin() {
        counters = Counters()
    }

    func snapshot() -> HiddenBarController.PerformanceSnapshot? {
        counters?.snapshot
    }

    func end() -> HiddenBarController.PerformanceSnapshot? {
        let snapshot = counters?.snapshot
        counters = nil
        return snapshot
    }

    func recordRefresh() {
        counters?.refreshEvents &+= 1
    }

    func recordQuery() {
        counters?.menuGuardQueries &+= 1
    }

    func recordTaskStarted() {
        counters?.reconcealTasksStarted &+= 1
    }

    func recordTaskCancelled(reason: HiddenBarController.MenuGuardTerminalReason) {
        counters?.reconcealTasksCancelled &+= 1
        counters?.terminalReason = reason
    }

    func recordTerminal(reason: HiddenBarController.MenuGuardTerminalReason) {
        counters?.terminalReason = reason
    }

    func recordDeferral(_ count: Int) {
        guard var counters else { return }
        counters.menuGuardDeferrals &+= 1
        counters.maximumConsecutiveDeferrals = max(counters.maximumConsecutiveDeferrals, count)
        self.counters = counters
    }
}
