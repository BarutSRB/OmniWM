// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Observation
import SwiftUI

@testable import OmniWM

struct SettingsSceneRedirectView: View {
    @Bindable var bootstrap: AppBootstrapState

    @State private var window: NSWindow?
    @State private var didRedirect = false

    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(didRedirect ? "Opening OmniWM Settings…" : "Starting OmniWM…")
                .foregroundColor(.secondary)
        }
        .frame(width: 1, height: 1)
        .background(
            WindowCaptureView { newWindow in
                updateWindow(newWindow)
            }
        )
        .onAppear {
            redirectIfPossible()
        }
        .onChange(of: bootstrap.settings != nil && bootstrap.controller != nil) { _, _ in
            redirectIfPossible()
        }
        .onDisappear {
            if let window {
                OwnedWindowRegistry.shared.unregister(window)
            }
        }
    }

    private func updateWindow(_ newWindow: NSWindow?) {
        if let window {
            if let newWindow {
                if window !== newWindow {
                    OwnedWindowRegistry.shared.unregister(window)
                }
            } else {
                OwnedWindowRegistry.shared.unregister(window)
            }
        }
        window = newWindow
        if let newWindow {
            OwnedWindowRegistry.shared.register(newWindow)
        }
        redirectIfPossible()
    }

    private func redirectIfPossible() {
        guard !didRedirect,
              let settings = bootstrap.settings,
              let controller = bootstrap.controller
        else { return }

        didRedirect = true
        SettingsWindowController.shared.show(
            settings: settings,
            controller: controller,
            updateCoordinator: bootstrap.updateCoordinator
        )

        guard let window else { return }
        OwnedWindowRegistry.shared.unregister(window)
        DispatchQueue.main.async {
            window.close()
        }
    }
}

private struct WindowCaptureView: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowCaptureNSView {
        WindowCaptureNSView(onChange: onChange)
    }

    func updateNSView(_ nsView: WindowCaptureNSView, context: Context) {
        nsView.onChange = onChange
    }
}

private final class WindowCaptureNSView: NSView {
    var onChange: (NSWindow?) -> Void

    init(onChange: @escaping (NSWindow?) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onChange(window)
    }
}
