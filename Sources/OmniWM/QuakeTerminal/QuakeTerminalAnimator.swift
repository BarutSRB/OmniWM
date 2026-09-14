// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Cocoa
import GhosttyKit

@MainActor
final class QuakeTerminalAnimator {
    enum CompletionPhase { case immediate, animated }
    private let settings: SettingsStore
    private let motionPolicy: MotionPolicy
    private var animationGeneration: UInt64 = 0

    init(settings: SettingsStore, motionPolicy: MotionPolicy) {
        self.settings = settings
        self.motionPolicy = motionPolicy
    }

    func invalidate() {
        animationGeneration &+= 1
    }

    func animateIn(
        window: QuakeTerminalWindow,
        screen: NSScreen,
        customFrame: () -> NSRect?,
        orderFront: (NSWindow) -> Void,
        completion: @escaping @MainActor (CompletionPhase) -> Void
    ) {
        let generation = beginAnimationTransition()

        if let customFrame = customFrame() {
            window.setFrame(customFrame, display: false)
            window.level = .popUpMenu
            orderFront(window)

            if !motionPolicy.animationsEnabled {
                completion(.immediate)
                return
            }

            window.alphaValue = 0
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = settings.quakeTerminal.animationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 1
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.animationGeneration == generation else { return }
                    completion(.animated)
                }
            })
            return
        }

        let placement = QuakeTerminalPlacement(
            position: settings.quakeTerminal.position,
            on: screen,
            widthPercent: settings.quakeTerminal.widthPercent,
            heightPercent: settings.quakeTerminal.heightPercent
        )

        placement.setInitial(in: window)

        window.level = .popUpMenu
        orderFront(window)

        if !motionPolicy.animationsEnabled {
            placement.setFinal(in: window)
            completion(.immediate)
            return
        }

        window.isAnimating = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = settings.quakeTerminal.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            placement.setFinal(in: window.animator())
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.animationGeneration == generation else { return }
                completion(.animated)
            }
        })
    }

    func animateOut(
        window: QuakeTerminalWindow,
        screen: () -> NSScreen,
        completion: @escaping @MainActor (CompletionPhase) -> Void
    ) {
        let generation = beginAnimationTransition()

        window.level = .popUpMenu

        if settings.quakeTerminalUseCustomFrame {
            if !motionPolicy.animationsEnabled {
                completion(.immediate)
                return
            }

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = settings.quakeTerminal.animationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.animationGeneration == generation else { return }
                    completion(.animated)
                }
            })
            return
        }

        let placement = QuakeTerminalPlacement(
            position: settings.quakeTerminal.position,
            on: screen(),
            widthPercent: settings.quakeTerminal.widthPercent,
            heightPercent: settings.quakeTerminal.heightPercent
        )

        if !motionPolicy.animationsEnabled {
            placement.setInitial(in: window)
            completion(.immediate)
            return
        }

        window.isAnimating = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = settings.quakeTerminal.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            placement.setInitial(in: window.animator())
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.animationGeneration == generation else { return }
                completion(.animated)
            }
        })
    }

    private func beginAnimationTransition() -> UInt64 {
        animationGeneration &+= 1
        return animationGeneration
    }
}
