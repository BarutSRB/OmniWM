import Cocoa
import GhosttyKit

@MainActor
final class QuakeTerminalController: NSObject, NSWindowDelegate {
    private var window: QuakeTerminalWindow?
    private var ghosttyApp: ghostty_app_t?
    private var ghosttyConfig: ghostty_config_t?
    private var surface: ghostty_surface_t?
    private var surfaceView: GhosttySurfaceView?

    private(set) var visible: Bool = false
    private var previousApp: NSRunningApplication?
    private var isHandlingResize: Bool = false

    private let settings: SettingsStore

    private static var ghosttyInitialized = false

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
    }

    private func initializeGhosttyIfNeeded() {
        guard !Self.ghosttyInitialized else { return }
        let result = ghostty_init(0, nil)
        if result == GHOSTTY_SUCCESS {
            Self.ghosttyInitialized = true
        } else {
            print("QuakeTerminal: ghostty_init failed with code \(result)")
        }
    }

    func setup() {
        guard ghosttyApp == nil else { return }

        initializeGhosttyIfNeeded()
        guard Self.ghosttyInitialized else {
            print("QuakeTerminal: GhosttyKit not initialized")
            return
        }

        ghosttyConfig = ghostty_config_new()
        guard ghosttyConfig != nil else {
            print("QuakeTerminal: Failed to create ghostty config")
            return
        }

        ghostty_config_load_default_files(ghosttyConfig)
        ghostty_config_finalize(ghosttyConfig)

        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = true
        runtimeConfig.wakeup_cb = { userdata in
            guard let userdata else { return }
            DispatchQueue.main.async {
                let controller = Unmanaged<QuakeTerminalController>.fromOpaque(userdata).takeUnretainedValue()
                controller.tick()
            }
        }
        runtimeConfig.action_cb = { _, _, _ in false }
        runtimeConfig.read_clipboard_cb = { userdata, location, state in
            guard let userdata else { return }
            DispatchQueue.main.async {
                let controller = Unmanaged<QuakeTerminalController>.fromOpaque(userdata).takeUnretainedValue()
                controller.readClipboard(location: location, state: state)
            }
        }
        runtimeConfig.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtimeConfig.write_clipboard_cb = { userdata, location, content, len, confirm in
            guard let userdata else { return }
            DispatchQueue.main.async {
                let controller = Unmanaged<QuakeTerminalController>.fromOpaque(userdata).takeUnretainedValue()
                controller.writeClipboard(location: location, content: content, len: len, confirm: confirm)
            }
        }
        runtimeConfig.close_surface_cb = { userdata, processAlive in
            guard let userdata else { return }
            DispatchQueue.main.async {
                let controller = Unmanaged<QuakeTerminalController>.fromOpaque(userdata).takeUnretainedValue()
                controller.surfaceClosed(processAlive: processAlive)
            }
        }

        ghosttyApp = ghostty_app_new(&runtimeConfig, ghosttyConfig)
        guard ghosttyApp != nil else {
            print("QuakeTerminal: Failed to create ghostty app")
            return
        }

        createWindow()
    }

    func cleanup() {
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
        if let ghosttyApp {
            ghostty_app_free(ghosttyApp)
            self.ghosttyApp = nil
        }
        if let ghosttyConfig {
            ghostty_config_free(ghosttyConfig)
            self.ghosttyConfig = nil
        }
        window?.close()
        window = nil
        surfaceView = nil
    }

    private func tick() {
        guard let ghosttyApp else { return }
        ghostty_app_tick(ghosttyApp)
    }

    private func createWindow() {
        let win = QuakeTerminalWindow()
        win.delegate = self
        self.window = win
    }

    private func createSurface() {
        guard let ghosttyApp, surfaceView == nil else { return }

        let userdata = Unmanaged.passUnretained(self).toOpaque()
        let view = GhosttySurfaceView(ghosttyApp: ghosttyApp, userdata: userdata)
        guard let newSurface = view.ghosttySurface else { return }

        surface = newSurface
        surfaceView = view
        window?.contentView = view

        if let window, let screen = NSScreen.main {
            let position = settings.quakeTerminalPosition
            position.setFinal(
                in: window,
                on: screen,
                widthPercent: settings.quakeTerminalWidthPercent,
                heightPercent: settings.quakeTerminalHeightPercent
            )
        }
    }

    func toggle() {
        if visible {
            animateOut()
        } else {
            animateIn()
        }
    }

    func animateIn() {
        guard let window else { return }
        guard !visible else { return }

        visible = true

        if !NSApp.isActive {
            if let previousApp = NSWorkspace.shared.frontmostApplication,
               previousApp.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.previousApp = previousApp
            }
        }

        if surface == nil {
            createSurface()
        }

        animateWindowIn(window: window)
    }

    func animateOut() {
        guard let window else { return }
        guard visible else { return }

        visible = false
        animateWindowOut(window: window)
    }

    private func animateWindowIn(window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let position = settings.quakeTerminalPosition
        let widthPercent = settings.quakeTerminalWidthPercent
        let heightPercent = settings.quakeTerminalHeightPercent

        position.setInitial(
            in: window,
            on: screen,
            widthPercent: widthPercent,
            heightPercent: heightPercent
        )

        window.level = .popUpMenu
        window.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = settings.quakeTerminalAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            position.setFinal(
                in: window.animator(),
                on: screen,
                widthPercent: widthPercent,
                heightPercent: heightPercent
            )
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.visible else { return }
                window.level = .floating
                self.makeWindowKey(window)

                if !NSApp.isActive {
                    NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.async {
                        guard !window.isKeyWindow else { return }
                        self.makeWindowKey(window, retries: 10)
                    }
                }
            }
        })
    }

    private func animateWindowOut(window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let position = settings.quakeTerminalPosition
        let widthPercent = settings.quakeTerminalWidthPercent
        let heightPercent = settings.quakeTerminalHeightPercent

        if let previousApp = self.previousApp {
            self.previousApp = nil
            if !previousApp.isTerminated {
                _ = previousApp.activate(options: [])
            }
        }

        window.level = .popUpMenu

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = settings.quakeTerminalAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            position.setInitial(
                in: window.animator(),
                on: screen,
                widthPercent: widthPercent,
                heightPercent: heightPercent
            )
        }, completionHandler: {
            Task { @MainActor in
                window.orderOut(nil)
            }
        })
    }

    private func makeWindowKey(_ window: NSWindow, retries: UInt8 = 0) {
        guard visible else { return }
        window.makeKeyAndOrderFront(nil)

        if let surfaceView {
            window.makeFirstResponder(surfaceView)
        }

        guard !window.isKeyWindow, retries > 0 else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in
            self?.makeWindowKey(window, retries: retries - 1)
        }
    }

    private func readClipboard(location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) {
        guard let surface else { return }
        let pasteboard = location == GHOSTTY_CLIPBOARD_SELECTION ? NSPasteboard(name: .find) : NSPasteboard.general
        let str = pasteboard.string(forType: .string) ?? ""
        str.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
        }
    }

    private func writeClipboard(location: ghostty_clipboard_e, content: UnsafePointer<ghostty_clipboard_content_s>?, len: Int, confirm: Bool) {
        guard let content, len > 0 else { return }
        let pasteboard = location == GHOSTTY_CLIPBOARD_SELECTION ? NSPasteboard(name: .find) : NSPasteboard.general
        pasteboard.clearContents()
        if let data = content.pointee.data {
            pasteboard.setString(String(cString: data), forType: .string)
        }
    }

    private func surfaceClosed(processAlive: Bool) {
        if !processAlive {
            surface = nil
            surfaceView = nil
            window?.contentView = nil
        }
        if visible {
            animateOut()
        }
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in
            guard visible else { return }
            guard window?.attachedSheet == nil else { return }

            if NSApp.isActive {
                self.previousApp = nil
            }

            if settings.quakeTerminalAutoHide {
                animateOut()
            }
        }
    }

    nonisolated func windowDidResize(_ notification: Notification) {
        guard let notificationWindow = notification.object as? NSWindow else { return }
        Task { @MainActor in
            guard notificationWindow == self.window,
                  visible,
                  !isHandlingResize else { return }
            guard let window = self.window,
                  let screen = window.screen ?? NSScreen.main else { return }

            isHandlingResize = true
            defer { isHandlingResize = false }

            let position = settings.quakeTerminalPosition
            switch position {
            case .top, .bottom, .center:
                let newOrigin = position.centeredOrigin(for: window, on: screen)
                window.setFrameOrigin(newOrigin)
            case .left, .right:
                let newOrigin = position.verticallyCenteredOrigin(for: window, on: screen)
                window.setFrameOrigin(newOrigin)
            }

            if let surface, let surfaceView {
                let size = surfaceView.frame.size
                let scale = window.backingScaleFactor
                ghostty_surface_set_size(surface, UInt32(size.width * scale), UInt32(size.height * scale))
            }
        }
    }
}
