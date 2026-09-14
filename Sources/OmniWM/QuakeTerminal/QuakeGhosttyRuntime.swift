// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import GhosttyKit

@MainActor
final class QuakeGhosttyRuntime {
    private var ghosttyApp: ghostty_app_t?
    private var ghosttyConfig: ghostty_config_t?
    private var retainedAppCallbackContext: Unmanaged<GhosttyAppCallbackContext>?
    private var appearanceObserver: NSKeyValueObservation?
    private var appliedColorScheme: ghostty_color_scheme_e?
    private let settings: SettingsStore
    private let ghosttyConfigBuilder: QuakeGhosttyConfigBuilder

    private static var ghosttyInitialized = false

    init(settings: SettingsStore, configBuilder: QuakeGhosttyConfigBuilder) {
        self.settings = settings
        ghosttyConfigBuilder = configBuilder
    }

    func startIfNeeded(for controller: QuakeTerminalController) -> Bool {
        guard ghosttyApp == nil else { return false }

        initializeGhosttyIfNeeded()
        guard Self.ghosttyInitialized else {
            Log.terminal.error("GhosttyKit not initialized")
            return false
        }

        guard let config = makeGhosttyConfig() else {
            Log.terminal.error("Failed to create ghostty config")
            return false
        }
        ghosttyConfig = config
        controller.updateGhosttyAppearance(QuakeGhosttyAppearance(config: config))

        let retainedAppContext = Unmanaged.passRetained(GhosttyAppCallbackContext(controller: controller))
        var runtimeConfig = makeRuntimeConfiguration(userdata: retainedAppContext.toOpaque())

        ghosttyApp = ghostty_app_new(&runtimeConfig, config)
        guard ghosttyApp != nil else {
            retainedAppContext.release()
            Log.terminal.error("Failed to create ghostty app")
            ghostty_config_free(config)
            ghosttyConfig = nil
            controller.updateGhosttyAppearance(nil)
            return false
        }
        retainedAppCallbackContext = retainedAppContext

        startGhosttyAppearanceSync(for: controller)
        applyCurrentGhosttyColorScheme()
        return true
    }

    private func makeRuntimeConfiguration(userdata: UnsafeMutableRawPointer) -> ghostty_runtime_config_s {
        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = userdata
        runtimeConfig.supports_selection_clipboard = true
        GhosttyAppCallbackContext.installWakeupCallback(in: &runtimeConfig)
        GhosttyAppCallbackContext.installActionCallback(in: &runtimeConfig)
        QuakeClipboardPromptCoordinator.installReadCallback(in: &runtimeConfig)
        QuakeClipboardPromptCoordinator.installConfirmationCallback(in: &runtimeConfig)
        QuakeClipboardPromptCoordinator.installWriteCallback(in: &runtimeConfig)
        GhosttySurfaceCallbackContext.installCloseCallback(in: &runtimeConfig)
        return runtimeConfig
    }

    func releaseAppAndConfiguration() {
        if let ghosttyApp {
            ghostty_app_free(ghosttyApp)
            self.ghosttyApp = nil
        }
        if let retainedAppCallbackContext {
            retainedAppCallbackContext.release()
            self.retainedAppCallbackContext = nil
        }
        if let ghosttyConfig {
            ghostty_config_free(ghosttyConfig)
            self.ghosttyConfig = nil
        }
    }

    private func initializeGhosttyIfNeeded() {
        guard !Self.ghosttyInitialized else { return }
        let result = ghostty_init(0, nil)
        Self.restoreCNumericLocale()
        if result == GHOSTTY_SUCCESS {
            Self.ghosttyInitialized = true
        } else {
            Log.terminal.error("ghostty_init failed with code \(result)")
        }
    }

    static func restoreCNumericLocale() {
        _ = setlocale(LC_NUMERIC, "C")
    }

    private func makeGhosttyConfig() -> ghostty_config_t? {
        ghosttyConfigBuilder.build(
            opacity: settings.quakeTerminal.opacity,
            backgroundEffect: settings.quakeTerminal.backgroundEffect
        )
    }

    func reloadConfiguration(for controller: QuakeTerminalController) {
        guard let ghosttyApp else { return }
        guard let newConfig = makeGhosttyConfig() else { return }

        controller.prepareForGhosttyConfigurationUpdate()
        ghostty_app_update_config(ghosttyApp, newConfig)
        if let ghosttyConfig {
            ghostty_config_free(ghosttyConfig)
        }
        ghosttyConfig = newConfig
        applyCurrentGhosttyColorScheme()
    }

    func reloadConfiguration(soft: Bool, for controller: QuakeTerminalController) {
        guard let ghosttyApp else { return }
        guard soft, let ghosttyConfig else {
            reloadConfiguration(for: controller)
            return
        }
        ghostty_app_update_config(ghosttyApp, ghosttyConfig)
    }

    func receiveAppearance(_ appearance: QuakeGhosttyAppearance, for controller: QuakeTerminalController) {
        guard ghosttyApp != nil else { return }
        controller.updateGhosttyAppearance(appearance, deferred: true)
    }

    private func startGhosttyAppearanceSync(for controller: QuakeTerminalController) {
        appearanceObserver = NSApplication.shared.observe(
            \.effectiveAppearance,
            options: [.new, .initial]
        ) { [weak controller] _, _ in
            Task { @MainActor [weak controller] in
                guard let controller else { return }
                controller.ghosttyRuntime.applyCurrentGhosttyColorScheme()
            }
        }
    }

    func stopAppearanceSync() {
        appearanceObserver?.invalidate()
        appearanceObserver = nil
        appliedColorScheme = nil
    }

    private func applyCurrentGhosttyColorScheme() {
        applyGhosttyColorScheme(for: NSApplication.shared.effectiveAppearance)
    }

    private func applyGhosttyColorScheme(for appearance: NSAppearance) {
        guard let ghosttyApp else { return }
        let scheme = Self.ghosttyColorScheme(for: appearance)
        guard appliedColorScheme != scheme else { return }
        ghostty_app_set_color_scheme(ghosttyApp, scheme)
        appliedColorScheme = scheme
    }

    static func ghosttyColorScheme(for appearance: NSAppearance) -> ghostty_color_scheme_e {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? GHOSTTY_COLOR_SCHEME_DARK
            : GHOSTTY_COLOR_SCHEME_LIGHT
    }

    func tick() {
        guard let ghosttyApp else { return }
        ghostty_app_tick(ghosttyApp)
    }

    func makeSurfaceView(for controller: QuakeTerminalController) -> GhosttySurfaceView? {
        guard let ghosttyApp else { return nil }
        let context = GhosttySurfaceCallbackContext(controller: controller)
        let view = GhosttySurfaceView(ghosttyApp: ghosttyApp, callbackContext: context)
        guard view.ghosttySurface != nil else { return nil }
        return view
    }
}
