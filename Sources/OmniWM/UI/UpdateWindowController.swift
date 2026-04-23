// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import SwiftUI

@MainActor
final class UpdateWindowController: UpdateWindowControlling {
    static let shared = UpdateWindowController()

    var onWindowClosedWithoutAction: (() -> Void)?

    private var window: NSWindow?
    private let ownedWindowRegistry = OwnedWindowRegistry.shared
    private var actionHandledOnClose = false

    func show(configuration: UpdatePopupConfiguration) {
        if let window,
           let hosting = window.contentViewController as? NSHostingController<UpdatePopupView>
        {
            actionHandledOnClose = false
            hosting.rootView = UpdatePopupView(configuration: configuration)
            center(window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: UpdatePopupView(configuration: configuration))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Update Available"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.setContentSize(NSSize(width: 720, height: 560))
        window.minSize = NSSize(width: 620, height: 460)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        center(window)

        ownedWindowRegistry.register(window)
        actionHandledOnClose = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default
            .addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.ownedWindowRegistry.unregister(window)
                    let shouldNotify = !self.actionHandledOnClose
                    self.actionHandledOnClose = false
                    self.window = nil
                    if shouldNotify {
                        self.onWindowClosedWithoutAction?()
                    }
                }
            }
        self.window = window
    }

    func close(markingActionHandled: Bool) {
        if markingActionHandled {
            actionHandledOnClose = true
        }
        window?.close()
    }

    var windowForTests: NSWindow? {
        window
    }

    private func center(_ window: NSWindow) {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) else {
            window.center()
            return
        }

        let origin = CGPoint(
            x: screen.frame.midX - window.frame.width / 2,
            y: screen.frame.midY - window.frame.height / 2
        )
        window.setFrameOrigin(origin)
    }
}

private struct UpdatePopupView: View {
    let configuration: UpdatePopupConfiguration

    @State private var copiedCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            versionStrip
            releaseNotesSection
            footer
        }
        .padding(28)
        .frame(width: 720, height: 560)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("OmniWM Update Available")
                    .font(.system(size: 28, weight: .bold))
            }

            Text(configuration.releaseTitle)
                .font(.system(size: 16, weight: .semibold))

            if let publishedDateText = configuration.publishedDateText {
                Text("Published \(publishedDateText)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var versionStrip: some View {
        HStack(spacing: 12) {
            versionCard(label: "Current", value: configuration.currentVersion)
            versionCard(label: "Latest", value: configuration.latestVersion)
            Spacer()
            commandChip
        }
    }

    private func versionCard(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var commandChip: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text("Manual update command")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(UpdateCoordinator.homebrewUpdateCommand)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.14))
                .clipShape(Capsule())
        }
    }

    private var releaseNotesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Release Notes")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            ScrollView {
                Text(configuration.releaseNotes)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
            }
            .padding(16)
            .background(.black.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Updates stay manual. OmniWM can open the release page or copy the Homebrew upgrade command for you.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Skip This Version") {
                    configuration.skipThisVersion()
                }
                .buttonStyle(.glass)

                Button("Not Now") {
                    configuration.notNow()
                }
                .buttonStyle(.glass)

                Spacer()

                Button(copiedCommand ? "Copied" : "Copy brew upgrade omniwm") {
                    configuration.copyCommand()
                    copiedCommand = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copiedCommand = false
                    }
                }
                .buttonStyle(.glass)

                Button("Open Release Page") {
                    configuration.openReleasePage()
                }
                .buttonStyle(.glassProminent)
            }
        }
    }
}
