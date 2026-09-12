// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
final class WindowRuleReevaluationScheduler {
    private weak var controller: WMController?
    private var pendingWindowRuleReevaluationTask: Task<Void, Never>?
    private var pendingWindowRuleReevaluationTargets: Set<WindowRuleReevaluationTarget> = []
    private var pendingWindowRuleReevaluationGeneration: UInt64 = 0

    init(controller: WMController) {
        self.controller = controller
    }

    func reset() {
        pendingWindowRuleReevaluationTask?.cancel()
        pendingWindowRuleReevaluationTask = nil
        pendingWindowRuleReevaluationTargets.removeAll()
        pendingWindowRuleReevaluationGeneration &+= 1
    }

    func schedule(
        targets: Set<WindowRuleReevaluationTarget>
    ) {
        guard let controller,
              controller.windowRuleEngine.needsWindowReevaluation,
              !targets.isEmpty
        else {
            return
        }

        pendingWindowRuleReevaluationTargets.formUnion(targets)
        pendingWindowRuleReevaluationTask?.cancel()
        pendingWindowRuleReevaluationGeneration &+= 1
        let generation = pendingWindowRuleReevaluationGeneration
        pendingWindowRuleReevaluationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.pendingWindowRuleReevaluationGeneration == generation,
                  let controller = self.controller
            else { return }
            guard controller.niriLayoutHandler.scrollAnimationByDisplay.isEmpty else {
                self.pendingWindowRuleReevaluationTask = nil
                self.schedule(targets: self.pendingWindowRuleReevaluationTargets)
                return
            }
            let targets = self.pendingWindowRuleReevaluationTargets
            self.pendingWindowRuleReevaluationTargets.removeAll()
            self.pendingWindowRuleReevaluationTask = nil
            let outcome = await controller.reevaluateWindowRules(for: targets)
            if outcome.stale {
                self.schedule(targets: targets)
            }
        }
    }
}
