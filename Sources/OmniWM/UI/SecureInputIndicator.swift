import AppKit
import SwiftUI

private let iconSize = CGSize(width: 44, height: 44)
private let expandedSize = CGSize(width: 380, height: 100)

@MainActor
final class SecureInputIndicatorController {
    static let shared = SecureInputIndicatorController()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<SecureInputIndicatorView>?
    private var isExpanded = false

    private init() {}

    func show() {
        if panel == nil {
            createPanel()
        }
        updateFrame()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        isExpanded = false
    }

    func toggle() {
        isExpanded.toggle()
        updateFrame()
        if let hostingView {
            hostingView.rootView = SecureInputIndicatorView(
                isExpanded: isExpanded,
                onTap: { [weak self] in self?.toggle() }
            )
        }
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .hudWindow, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.alphaValue = 1
        panel.hasShadow = true
        panel.backgroundColor = .clear

        let view = SecureInputIndicatorView(
            isExpanded: isExpanded,
            onTap: { [weak self] in self?.toggle() }
        )
        let hostingView = NSHostingView(rootView: view)
        panel.contentView = hostingView

        self.panel = panel
        self.hostingView = hostingView
    }

    private func updateFrame() {
        guard let panel, let screen = NSScreen.main else { return }

        let size = isExpanded ? expandedSize : iconSize
        let x = screen.frame.maxX - size.width - 20
        let y: CGFloat = 20

        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        hostingView?.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
    }
}

struct SecureInputIndicatorView: View {
    let isExpanded: Bool
    let onTap: () -> Void

    @Environment(\.colorScheme) var colorScheme

    private var backgroundColor: Color {
        colorScheme == .dark ? Color.gray.opacity(0.9) : Color.gray.opacity(0.85)
    }

    private var foregroundColor: Color {
        colorScheme == .dark ? .black : .white
    }

    var body: some View {
        ZStack(alignment: .center) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(backgroundColor)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "lock.shield.fill")
                            .font(.title2)
                        Text("Secure Input Active")
                            .font(.headline)
                    }
                    Text(
                        "OmniWM keyboard shortcuts are disabled while a password field or secure text entry is active."
                    )
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                }
                .padding(16)
            } else {
                Image(systemName: "lock.shield.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(10)
            }
        }
        .foregroundStyle(foregroundColor)
        .frame(
            width: isExpanded ? expandedSize.width : iconSize.width,
            height: isExpanded ? expandedSize.height : iconSize.height
        )
        .onTapGesture {
            onTap()
        }
    }
}
