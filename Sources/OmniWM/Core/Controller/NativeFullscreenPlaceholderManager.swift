// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

struct NativeFullscreenPlaceholderUpdate: Equatable {
    let token: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    let frame: CGRect
    let selected: Bool
    let appName: String?
    let icon: NSImage?
}

struct NativeFullscreenPlaceholderSnapshot: Equatable {
    let workspaceId: WorkspaceDescriptor.ID
    let frame: CGRect
    let selected: Bool
    let appName: String?
}

@MainActor
final class NativeFullscreenPlaceholderManager {
    var onActivate: ((WindowToken) -> Void)?

    private var windowsByToken: [WindowToken: NativeFullscreenPlaceholderWindow] = [:]

    func apply(_ placeholders: [NativeFullscreenPlaceholderUpdate]) {
        let desiredTokens = Set(placeholders.map(\.token))
        let staleWindowTokens = windowsByToken.keys.filter { !desiredTokens.contains($0) }
        for token in staleWindowTokens {
            windowsByToken.removeValue(forKey: token)?.destroy()
        }

        for placeholder in placeholders {
            let window = windowsByToken[placeholder.token] ?? {
                let window = NativeFullscreenPlaceholderWindow(token: placeholder.token)
                window.onActivate = { [weak self] token in
                    self?.onActivate?(token)
                }
                windowsByToken[placeholder.token] = window
                return window
            }()
            window.update(placeholder)
        }
    }

    func removeAll() {
        for window in windowsByToken.values {
            window.destroy()
        }
        windowsByToken.removeAll()
    }
}

@MainActor
private final class NativeFullscreenPlaceholderWindow: NSPanel {
    private let placeholderView = NativeFullscreenPlaceholderView(frame: .zero)
    private var token: WindowToken
    private var surfaceId: String
    private var lastUpdate: NativeFullscreenPlaceholderSnapshot?
    private var registeredSurfaceId: String?

    var workspaceId: WorkspaceDescriptor.ID?
    var onActivate: ((WindowToken) -> Void)?

    init(token: WindowToken) {
        self.token = token
        surfaceId = Self.surfaceId(for: token)
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        isOpaque = true
        backgroundColor = .black
        level = .floating
        ignoresMouseEvents = false
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.managed, .fullScreenNone]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false

        placeholderView.onActivate = { [weak self] in
            self?.activate()
        }
        contentView = placeholderView
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    func update(_ update: NativeFullscreenPlaceholderUpdate) {
        token = update.token
        workspaceId = update.workspaceId
        let nextSnapshot = NativeFullscreenPlaceholderSnapshot(
            workspaceId: update.workspaceId,
            frame: update.frame,
            selected: update.selected,
            appName: update.appName
        )
        let contentChanged = placeholderView.update(
            appName: update.appName,
            icon: update.icon,
            selected: update.selected
        )

        if lastUpdate != nextSnapshot || frame != update.frame {
            setFrame(update.frame, display: contentChanged)
            placeholderView.frame = CGRect(origin: .zero, size: update.frame.size)
            lastUpdate = nextSnapshot
        } else if contentChanged {
            contentView?.displayIfNeeded()
        }

        if update.frame.width > 1, update.frame.height > 1 {
            registerSurfaceIfNeeded()
            if !isVisible {
                orderFront(nil)
            }
        } else {
            orderOut(nil)
        }
    }

    func activate() {
        onActivate?(token)
    }

    func destroy() {
        unregisterSurface()
        orderOut(nil)
        close()
    }

    private func registerSurfaceIfNeeded() {
        guard registeredSurfaceId != surfaceId else { return }
        unregisterSurface()
        OwnedWindowRegistry.shared.register(
            self,
            surfaceId: surfaceId,
            kind: .nativeFullscreenPlaceholder,
            hitTestPolicy: .interactive,
            capturePolicy: .excluded,
            suppressesManagedFocusRecovery: false
        )
        registeredSurfaceId = surfaceId
    }

    private func unregisterSurface() {
        guard let registeredSurfaceId else { return }
        OwnedWindowRegistry.shared.unregister(surfaceId: registeredSurfaceId)
        self.registeredSurfaceId = nil
    }

    private static func surfaceId(for token: WindowToken) -> String {
        "native-fullscreen-placeholder-\(token.pid)-\(token.windowId)"
    }
}

private final class NativeFullscreenPlaceholderView: NSView {
    private let iconView = NSImageView(frame: .zero)
    private let titleField = NSTextField(labelWithString: "In macOS Full Screen")
    private let subtitleField = NSTextField(labelWithString: "Move or resize this slot; the window will return here.")
    private var currentAppName: String?
    private var currentIcon: NSImage?
    private var isSelected = false

    var onActivate: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleField.alignment = .center
        titleField.font = .systemFont(ofSize: 17, weight: .semibold)
        titleField.textColor = .white
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false

        subtitleField.alignment = .center
        subtitleField.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleField.textColor = NSColor.white.withAlphaComponent(0.78)
        subtitleField.lineBreakMode = .byWordWrapping
        subtitleField.maximumNumberOfLines = 2
        subtitleField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleField)
        addSubview(subtitleField)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -28),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),

            titleField.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 14),
            titleField.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            titleField.centerXAnchor.constraint(equalTo: centerXAnchor),

            subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 6),
            subtitleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            subtitleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24)
        ])
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with _: NSEvent) {
        onActivate?()
    }

    func update(appName: String?, icon: NSImage?, selected: Bool) -> Bool {
        let changed = currentAppName != appName || currentIcon !== icon || isSelected != selected
        guard changed else { return false }

        currentAppName = appName
        currentIcon = icon
        isSelected = selected
        iconView.image = icon ?? NSImage(named: NSImage.applicationIconName)
        toolTip = appName
        titleField.stringValue = "In macOS Full Screen"
        refreshAppearance()
        return true
    }

    private func refreshAppearance() {
        guard let layer else { return }
        layer.cornerRadius = 8
        layer.borderWidth = isSelected ? 2 : 1
        layer.borderColor = (isSelected ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.28)).cgColor
        layer.backgroundColor = NSColor.black.cgColor
    }
}
