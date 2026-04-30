// SPDX-License-Identifier: GPL-2.0-only
import AppKit

@MainActor
final class HiddenBarController {
    nonisolated static let separatorAutosaveName = "omniwm_hiddenbar_separator"

    private let settings: SettingsStore

    private weak var omniButton: NSStatusBarButton?
    private var separatorItem: NSStatusItem?
    private var collapseLength: CGFloat = HiddenBarController.boundedCollapseLength(screenWidth: nil)
    private var hasAttemptedRuntimeRepairThisLaunch = false
    private var onUnsafeOrderingDetected: (() -> Void)?
    private var screenParametersObserver: NSObjectProtocol?

    private let separatorLength: CGFloat = 8

    private var isToggling = false

    private var isCollapsed: Bool {
        settings.hiddenBarIsCollapsed
    }

    init(settings: SettingsStore) {
        self.settings = settings
    }

    nonisolated static func boundedCollapseLength(screenWidth: CGFloat?) -> CGFloat {
        let resolvedWidth = screenWidth ?? 1728
        return max(500, min(resolvedWidth + 200, 4000))
    }

    nonisolated static func canCollapseSafely(
        omniMinX: CGFloat?,
        separatorMinX: CGFloat?,
        layoutDirection: NSUserInterfaceLayoutDirection
    ) -> Bool {
        guard let omniMinX, let separatorMinX else { return false }
        switch layoutDirection {
        case .rightToLeft:
            return omniMinX <= separatorMinX
        default:
            return omniMinX >= separatorMinX
        }
    }

    func bind(omniButton: NSStatusBarButton, onUnsafeOrderingDetected: @escaping () -> Void) {
        self.omniButton = omniButton
        self.onUnsafeOrderingDetected = onUnsafeOrderingDetected
        updateCollapseLength()
    }

    func setup() {
        guard separatorItem == nil else { return }

        separatorItem = NSStatusBar.system.statusItem(withLength: separatorLength)
        setupSeparator()
        separatorItem?.autosaveName = Self.separatorAutosaveName
        installScreenParametersObserverIfNeeded()
        updateCollapseLength()

        if settings.hiddenBarIsCollapsed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.collapse()
            }
        }
    }

    private func setupSeparator() {
        guard let button = separatorItem?.button else { return }
        button.image = NSImage(systemSymbolName: "line.diagonal", accessibilityDescription: "Separator")
        button.image?.isTemplate = true
        button.appearsDisabled = true
    }

    func toggle() {
        guard !isToggling else { return }
        isToggling = true

        guard separatorItem != nil else {
            settings.hiddenBarIsCollapsed.toggle()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.isToggling = false
            }
            return
        }

        if isCollapsed {
            expand()
        } else {
            collapse()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isToggling = false
        }
    }

    private func collapse() {
        guard !isCollapsed else { return }
        guard canCollapseSafely() else {
            settings.hiddenBarIsCollapsed = false
            requestRuntimeRepairIfNeeded()
            return
        }

        separatorItem?.length = collapseLength
        settings.hiddenBarIsCollapsed = true
    }

    private func expand() {
        guard isCollapsed else { return }

        separatorItem?.length = separatorLength
        settings.hiddenBarIsCollapsed = false
    }

    func cleanup() {
        if let observer = screenParametersObserver {
            NotificationCenter.default.removeObserver(observer)
            screenParametersObserver = nil
        }
        if let item = separatorItem {
            NSStatusBar.system.removeStatusItem(item)
            separatorItem = nil
        }
        omniButton = nil
        onUnsafeOrderingDetected = nil
    }

    func separatorAutosaveNameForTests() -> String? {
        separatorItem?.autosaveName
    }

    private func updateCollapseLength() {
        collapseLength = Self.boundedCollapseLength(screenWidth: currentScreenWidth())
        if isCollapsed {
            separatorItem?.length = collapseLength
        }
    }

    private func currentScreenWidth() -> CGFloat? {
        omniButton?.window?.screen?.frame.width ??
            separatorItem?.button?.window?.screen?.frame.width ??
            NSScreen.main?.frame.width
    }

    private func canCollapseSafely() -> Bool {
        let layoutDirection = NSApp?.userInterfaceLayoutDirection ?? .leftToRight
        return Self.canCollapseSafely(
            omniMinX: omniButton?.window?.frame.minX,
            separatorMinX: separatorItem?.button?.window?.frame.minX,
            layoutDirection: layoutDirection
        )
    }

    private func requestRuntimeRepairIfNeeded() {
        guard !hasAttemptedRuntimeRepairThisLaunch else { return }
        hasAttemptedRuntimeRepairThisLaunch = true
        onUnsafeOrderingDetected?()
    }

    private func installScreenParametersObserverIfNeeded() {
        guard screenParametersObserver == nil else { return }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateCollapseLength()
            }
        }
    }
}
