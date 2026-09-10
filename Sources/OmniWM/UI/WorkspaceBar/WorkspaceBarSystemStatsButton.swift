// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

@MainActor
struct SystemStatsButtonView: View {
    let itemHeight: CGFloat
    let accentColor: Color?
    let textColor: Color?
    let onToggle: () -> Void
    let onAnchorChange: (CGPoint?) -> Void

    @State private var isHovered = false

    private var buttonSize: CGFloat {
        max(18, itemHeight)
    }

    private var iconColor: Color {
        if isHovered {
            return accentColor ?? .accentColor
        }
        return textColor ?? .secondary
    }

    private var buttonShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
    }

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: "gauge.with.needle")
                .font(.system(size: max(11, itemHeight * 0.58), weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: buttonSize, height: buttonSize)
                .background {
                    buttonShape
                        .fill(isHovered ? .regularMaterial : .thinMaterial)
                        .overlay {
                            buttonShape.strokeBorder(Color.secondary.opacity(isHovered ? 0.3 : 0.18), lineWidth: 0.75)
                        }
                }
                .contentShape(buttonShape)
                .background(WorkspaceBarAnchorReporter(onChange: onAnchorChange))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("System stats")
        .help("Show system stats")
    }
}

private struct WorkspaceBarAnchorReporter: NSViewRepresentable {
    let onChange: (CGPoint?) -> Void

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.report(nsView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    @MainActor
    final class Coordinator {
        private let onChange: (CGPoint?) -> Void
        private var lastAnchor: CGPoint?

        init(onChange: @escaping (CGPoint?) -> Void) {
            self.onChange = onChange
        }

        func report(_ view: NSView) {
            let anchor: CGPoint?
            if let window = view.window {
                let localFrame = view.convert(view.bounds, to: nil)
                let screenFrame = window.convertToScreen(localFrame)
                anchor = WorkspaceBarGeometry.statsButtonAnchor(buttonFrame: screenFrame)
            } else {
                anchor = nil
            }
            if anchor != lastAnchor {
                lastAnchor = anchor
                onChange(anchor)
            }
        }
    }
}
