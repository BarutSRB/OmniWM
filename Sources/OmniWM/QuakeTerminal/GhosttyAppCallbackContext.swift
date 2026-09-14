// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import GhosttyKit

@MainActor
final class GhosttyAppCallbackContext {
    private weak var controller: QuakeTerminalController?

    init(controller: QuakeTerminalController) {
        self.controller = controller
    }

    static func installWakeupCallback(in runtimeConfig: inout ghostty_runtime_config_s) {
        runtimeConfig.wakeup_cb = { userdata in
            guard let userdata else { return }
            let context = Unmanaged<GhosttyAppCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                guard let controller = context.controller else { return }
                controller.ghosttyRuntime.tick()
            }
        }
    }

    static func installActionCallback(in runtimeConfig: inout ghostty_runtime_config_s) {
        runtimeConfig.action_cb = { app, target, action in
            guard let app, let userdata = ghostty_app_userdata(app) else { return false }
            switch action.tag {
            case GHOSTTY_ACTION_CONFIG_CHANGE:
                guard target.tag == GHOSTTY_TARGET_APP,
                      let config = action.action.config_change.config else { return false }
                let appearance = QuakeGhosttyAppearance(config: config)
                return MainActor.assumeIsolated {
                    let context = Unmanaged<GhosttyAppCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
                    guard let controller = context.controller else { return false }
                    controller.ghosttyRuntime.receiveAppearance(appearance, for: controller)
                    return true
                }
            case GHOSTTY_ACTION_RELOAD_CONFIG:
                guard target.tag == GHOSTTY_TARGET_APP else { return false }
                return MainActor.assumeIsolated {
                    let context = Unmanaged<GhosttyAppCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
                    guard let controller = context.controller else { return false }
                    controller.ghosttyRuntime.reloadConfiguration(
                        soft: action.action.reload_config.soft,
                        for: controller
                    )
                    return true
                }
            default:
                return false
            }
        }
    }
}
