import SwiftUI

struct GlassButtonStyle: ButtonStyle {
    var isProminent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(
                isProminent ? .regular.tint(.accentColor) : .regular,
                in: Capsule()
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

extension ButtonStyle where Self == GlassButtonStyle {
    static var glass: GlassButtonStyle { GlassButtonStyle() }
    static var glassProminent: GlassButtonStyle { GlassButtonStyle(isProminent: true) }
}

struct GlassCard<Content: View>: View {
    let content: Content
    var cornerRadius: CGFloat = 12

    init(cornerRadius: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}

struct GlassSearchField: View {
    @Binding var text: String
    var placeholder: String = "Search..."
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct GlassSectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)
            .tracking(0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }
}

struct StatusIndicator: View {
    @State private var isAnimating = false

    var body: some View {
        Circle()
            .fill(.green)
            .frame(width: 6, height: 6)
            .shadow(color: .green.opacity(0.5), radius: isAnimating ? 4 : 2)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    isAnimating = true
                }
            }
    }
}

struct GlassMenuRow<Content: View>: View {
    let content: Content
    var icon: String?
    var action: () -> Void
    var showChevron: Bool = false
    var isExternal: Bool = false
    var isDestructive: Bool = false
    var animationsEnabled: Bool = true

    @State private var isHovered = false
    @State private var isPressed = false

    init(
        icon: String? = nil,
        showChevron: Bool = false,
        isExternal: Bool = false,
        isDestructive: Bool = false,
        animationsEnabled: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.showChevron = showChevron
        self.isExternal = isExternal
        self.isDestructive = isDestructive
        self.animationsEnabled = animationsEnabled
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .foregroundStyle(iconColor)
                        .frame(width: 16)
                }
                content
                    .foregroundStyle(textColor)
                Spacer()

                if showChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }

                if isExternal {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(animationsEnabled ? .spring(duration: 0.2) : nil) { content in
            content.scaleEffect(isPressed ? 0.97 : 1.0)
        }
        .animation(animationsEnabled ? .easeOut(duration: 0.15) : nil) { content in
            content.background {
                if isHovered {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isDestructive ? AnyShapeStyle(Color.red.opacity(0.1)) : AnyShapeStyle(.quaternary))
                }
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }

    private var iconColor: Color {
        if isDestructive && isHovered { return .red }
        return .secondary
    }

    private var textColor: Color {
        if isDestructive && isHovered { return .red }
        return .primary
    }
}

struct GlassToggleRow: View {
    var icon: String?
    let label: String
    @Binding var isOn: Bool
    var animationsEnabled: Bool = true

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }

            Toggle(label, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .animation(animationsEnabled ? .easeOut(duration: 0.15) : nil) { content in
            content.background {
                if isHovered {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                }
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct GlassMenuSection<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 2) {
            content
        }
    }
}

struct GlassMenuDivider: View {
    var body: some View {
        Divider()
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
    }
}
