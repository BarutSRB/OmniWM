// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

struct HiddenBarActivationOwner: Equatable, Sendable {
    let pid: pid_t
    let allowsAuthoritativeEmpty: Bool
}

@MainActor
final class HiddenBarController {
    private struct ActiveActivation: Equatable {
        let bundleID: String
        let pid: pid_t
        let generation: Int
    }

    private let settings: SettingsStore
    private let hider = AssessmentModeHider()
    private let itemService: MenuBarItemService
    private let panel = HiddenBarPanelController()
    private let iconCache = HiddenBarIconCache()
    private let forwarder: HiddenBarClickForwarder
    private let fallbackIcon = HiddenBarFallbackIconController()

    var onFallbackIconClick: ((NSEvent, NSView) -> Void)?
    var fallbackPlacementsProvider: (() -> [HiddenBarFallbackIconPlacement])?

    private var refreshTimer: Timer?
    private var reconcealTask: Task<Void, Never>?
    private var reconcealGeneration = 0
    private var activationTask: Task<Void, Never>?
    private var activationGeneration = 0
    private var activeActivation: ActiveActivation?
    private var captureTask: Task<Void, Never>?
    private var captureBundleIDs: Set<String> = []
    private var captureGeneration = 0
    private var temporarilyRevealed: Set<String> = []
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var appLaunchObserver: NSObjectProtocol?
    private var appTerminationObserver: NSObjectProtocol?
    private weak var omniButton: NSStatusBarButton?
    private weak var omniStatusItem: NSStatusItem?

    private static let refreshInterval: TimeInterval = 1
    private static let menuGuardPollInterval: Duration = .milliseconds(250)
    private static let captureDeadline: Duration = .milliseconds(500)

    init(settings: SettingsStore) {
        self.settings = settings
        let itemService = MenuBarItemService()
        self.itemService = itemService
        forwarder = HiddenBarClickForwarder(itemService: itemService)
        panel.onActivate = { [weak self] key in
            self?.activateHiddenItem(key)
        }
        iconCache.onChange = { [weak self] in
            self?.refreshPanelIfVisible()
        }
        hider.onConcealingChanged = { [weak self] concealing in
            self?.handleConcealingChanged(concealing)
        }
        fallbackIcon.onClick = { [weak self] event, anchor in
            self?.onFallbackIconClick?(event, anchor)
        }
        panel.isExemptWindow = { [weak self] window in
            guard let self else { return false }
            return window === omniButton?.window || fallbackIcon.owns(window: window)
        }
    }

    var isHidingAvailable: Bool {
        hider.available
    }

    var onCursorWarp: ((CGPoint) -> Void)? {
        get { forwarder.onCursorWarp }
        set { forwarder.onCursorWarp = newValue }
    }

    func detectMenuBarApps() async -> [DetectedMenuBarApp] {
        let snapshot = runningAppsSnapshot()
        let apps = await itemService.scan(
            candidates: snapshot.candidates,
            ownBundleID: Bundle.main.bundleIdentifier
        )
        guard !Task.isCancelled else { return [] }
        hider.learn(apps)
        return apps
    }

    func displayName(for bundleID: String) -> String {
        hider.displayName(for: bundleID) ?? bundleID
    }

    func bind(omniButton: NSStatusBarButton, statusItem: NSStatusItem) {
        self.omniButton = omniButton
        omniStatusItem = statusItem
        statusItem.isVisible = !hider.isConcealing
    }

    private func handleConcealingChanged(_ concealing: Bool) {
        omniStatusItem?.isVisible = !concealing
        if concealing {
            syncFallbackIcon()
        } else {
            fallbackIcon.dismiss()
        }
    }

    private func syncFallbackIcon() {
        guard hider.isConcealing,
              let placements = fallbackPlacementsProvider?(), !placements.isEmpty
        else {
            fallbackIcon.dismiss()
            return
        }
        fallbackIcon.show(placements: placements)
    }

    func setup() {
        itemService.start()
        installDidBecomeActiveObserver()
        installRunningApplicationObservers()
        applySettings()
    }

    func applySettings() {
        hider.refreshAvailability()
        cancelCapture()
        let normalizedBundleIDs = HiddenBarSettingsPolicy.normalizedBundleIDs(
            settings.hiddenBarHiddenBundleIDs,
            additionalProtectedBundleIDs: [Bundle.main.bundleIdentifier ?? "com.barut.OmniWM"]
        )
        if settings.hiddenBarHiddenBundleIDs != normalizedBundleIDs {
            settings.hiddenBarHiddenBundleIDs = normalizedBundleIDs
        }
        let configured = Set(normalizedBundleIDs)
        temporarilyRevealed.formIntersection(configured)

        guard Self.wantsRefresh(
            enabled: settings.hiddenBarEnabled,
            available: hider.available,
            hiddenBundleIDs: configured
        ) else {
            clearTemporaryReveals()
            hider.drop()
            panel.dismiss()
            iconCache.prune(keeping: [])
            reconcileRefreshTimer()
            return
        }

        let snapshot = runningAppsSnapshot()
        temporarilyRevealed.formIntersection(snapshot.bundleIDs)
        cancelActivationIfInvalid(configured: configured, snapshot: snapshot)
        cancelReconcealIfNoTemporaryReveals()
        let hiddenRunning = configured.intersection(snapshot.bundleIDs)
        iconCache.prune(keeping: hiddenRunning)
        reconcileRefreshTimer()
        let unresolved = hiddenRunning.filter { !iconCache.hasResolvedItems(for: $0) }
        reconcileConcealment(snapshot: snapshot, captureBundleIDs: Set(unresolved))
        refreshPanelIfVisible()
    }

    func setEnabled(_ enabled: Bool) {
        settings.hiddenBarEnabled = enabled
        applySettings()
    }

    func togglePanel(placement: HiddenBarPanelPlacement?) {
        guard settings.hiddenBarEnabled, hider.available, let placement else { return }
        panel.toggle(placement: placement, items: currentGlyphs())
    }

    func dismissPanel() {
        panel.dismiss()
    }

    func refreshPanelIfVisible() {
        guard panel.isVisible else { return }
        panel.refresh(items: currentGlyphs())
    }

    func cleanup() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        cancelCapture()
        forwarder.cancel()
        clearTemporaryReveals()
        panel.dismiss()
        fallbackIcon.dismiss()
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
            self.didBecomeActiveObserver = nil
        }
        removeRunningApplicationObservers()
        hider.drop()
        itemService.stop()
    }

    private func reconcileRefreshTimer() {
        let wantsRefresh = Self.wantsRefresh(
            enabled: settings.hiddenBarEnabled,
            available: hider.available,
            hiddenBundleIDs: Set(settings.hiddenBarHiddenBundleIDs)
        )
        if wantsRefresh {
            if refreshTimer == nil {
                let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.handleRefreshTick()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                refreshTimer = timer
            }
        } else {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private func handleRefreshTick() {
        syncFallbackIcon()
        let configured = Set(settings.hiddenBarHiddenBundleIDs)
        guard Self.wantsRefresh(
            enabled: settings.hiddenBarEnabled,
            available: hider.available,
            hiddenBundleIDs: configured
        ) else { return }
        let snapshot = runningAppsSnapshot()
        iconCache.prune(keeping: configured.intersection(snapshot.bundleIDs))
        reconcileConcealment(snapshot: snapshot, captureBundleIDs: [])
    }

    private func applyConcealment(
        runningBundleIDs: Set<String>,
        bypassHysteresis: Bool = false
    ) {
        let configured = Set(settings.hiddenBarHiddenBundleIDs)
        guard Self.wantsRefresh(
            enabled: settings.hiddenBarEnabled,
            available: hider.available,
            hiddenBundleIDs: configured
        ) else { return }
        hider.apply(
            hiddenBundleIDs: Self.effectiveHiddenBundleIDs(
                configured: configured,
                temporarilyRevealed: temporarilyRevealed,
                pendingCapture: captureBundleIDs
            ),
            runningBundleIDs: runningBundleIDs,
            bypassHysteresis: bypassHysteresis
        )
    }

    private func reconcileConcealment(
        snapshot: RunningAppsSnapshot,
        captureBundleIDs requestedCaptureBundleIDs: Set<String>,
        bypassHysteresis: Bool = false
    ) {
        let eligible = Self.effectiveHiddenBundleIDs(
            configured: Set(settings.hiddenBarHiddenBundleIDs),
            temporarilyRevealed: temporarilyRevealed
        ).intersection(snapshot.bundleIDs)
        let targets = captureBundleIDs
            .union(requestedCaptureBundleIDs)
            .intersection(eligible)
        guard !targets.isEmpty else {
            if !captureBundleIDs.isEmpty {
                cancelCapture()
            }
            applyConcealment(
                runningBundleIDs: snapshot.bundleIDs,
                bypassHysteresis: bypassHysteresis
            )
            return
        }
        guard targets != captureBundleIDs || captureTask == nil else {
            applyConcealment(
                runningBundleIDs: snapshot.bundleIDs,
                bypassHysteresis: bypassHysteresis
            )
            return
        }
        scheduleCapture(
            bundleIDs: targets,
            snapshot: snapshot,
            bypassHysteresis: bypassHysteresis
        )
    }

    private func scheduleCapture(
        bundleIDs: Set<String>,
        snapshot: RunningAppsSnapshot,
        bypassHysteresis: Bool
    ) {
        let targets = bundleIDs
            .intersection(Self.effectiveHiddenBundleIDs(
                configured: Set(settings.hiddenBarHiddenBundleIDs),
                temporarilyRevealed: temporarilyRevealed
            ))
            .intersection(snapshot.bundleIDs)
        guard !targets.isEmpty else {
            applyConcealment(
                runningBundleIDs: snapshot.bundleIDs,
                bypassHysteresis: bypassHysteresis
            )
            return
        }

        captureTask?.cancel()
        captureGeneration += 1
        captureBundleIDs = targets
        let allowEmptyBundleIDs = targets.filter { iconCache.hasResolvedItems(for: $0) }
        applyConcealment(
            runningBundleIDs: snapshot.bundleIDs,
            bypassHysteresis: true
        )
        let generation = captureGeneration
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let resolution = await itemService.resolveItems(
                candidates: snapshot.candidates,
                bundleIDs: targets,
                allowEmptyBundleIDs: Set(allowEmptyBundleIDs)
            )
            guard !Task.isCancelled, generation == captureGeneration else { return }
            let icons = await HiddenBarIconCaptureService.captureVisible(
                resolution.items,
                timeout: Self.captureDeadline
            )
            guard !Task.isCancelled, generation == captureGeneration else { return }
            finishCapture(
                generation: generation,
                targets: targets,
                resolution: resolution,
                icons: icons
            )
        }
    }

    private func finishCapture(
        generation: Int,
        targets: Set<String>,
        resolution: MenuBarItemResolution,
        icons: [MenuBarItemKey: CapturedIcon]
    ) {
        guard generation == captureGeneration else { return }
        let snapshot = runningAppsSnapshot()
        let validTargets = targets
            .intersection(Set(settings.hiddenBarHiddenBundleIDs))
            .subtracting(temporarilyRevealed)
            .intersection(snapshot.bundleIDs)
        let resolved = resolution.itemsByBundleID.filter { validTargets.contains($0.key) }
        let captured = icons.filter { validTargets.contains($0.key.bundleID) }
        iconCache.replaceResolvedItems(
            resolved,
            capturedIcons: captured,
            replacingCapturedIcons: true
        )
        captureTask = nil
        captureBundleIDs.removeAll(keepingCapacity: true)
        applyConcealment(runningBundleIDs: snapshot.bundleIDs, bypassHysteresis: true)
    }

    private func cancelCapture() {
        captureGeneration += 1
        captureTask?.cancel()
        captureTask = nil
        captureBundleIDs.removeAll(keepingCapacity: true)
    }

    private func refreshVisibleIcons(_ bundleIDs: Set<String>) async {
        let snapshot = runningAppsSnapshot()
        let targets = bundleIDs.intersection(snapshot.bundleIDs)
        guard !targets.isEmpty else { return }
        let resolution = await itemService.resolveItems(
            candidates: snapshot.candidates,
            bundleIDs: targets,
            allowEmptyBundleIDs: targets.filter { iconCache.hasResolvedItems(for: $0) }
        )
        guard !Task.isCancelled else { return }
        let icons = await HiddenBarIconCaptureService.captureVisible(
            resolution.items,
            timeout: Self.captureDeadline
        )
        guard !Task.isCancelled else { return }
        let currentSnapshot = runningAppsSnapshot()
        let validTargets = targets
            .intersection(Set(settings.hiddenBarHiddenBundleIDs))
            .intersection(temporarilyRevealed)
            .intersection(currentSnapshot.bundleIDs)
        guard !validTargets.isEmpty else { return }
        let resolved = resolution.itemsByBundleID.filter { validTargets.contains($0.key) }
        let captured = icons.filter { validTargets.contains($0.key.bundleID) }
        iconCache.replaceResolvedItems(
            resolved,
            capturedIcons: captured,
            replacingCapturedIcons: true
        )
    }

    private func currentGlyphs() -> [HiddenBarGlyph] {
        var appsByBundleID: [String: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier, appsByBundleID[bundleID] == nil {
                appsByBundleID[bundleID] = app
            }
        }
        var glyphs: [HiddenBarGlyph] = []
        for bundleID in settings.hiddenBarHiddenBundleIDs {
            guard let app = appsByBundleID[bundleID] else { continue }
            let name = app.localizedName ?? displayName(for: bundleID)
            guard let resolved = iconCache.resolvedItems(for: bundleID) else {
                glyphs.append(
                    HiddenBarGlyph(
                        key: MenuBarItemKey(bundleID: bundleID, ordinal: 0),
                        name: name,
                        image: app.icon,
                        size: CGSize(width: 20, height: 20)
                    )
                )
                continue
            }
            guard !resolved.isEmpty else { continue }
            for item in resolved {
                if let icon = item.icon {
                    let size = CGSize(
                        width: CGFloat(icon.image.width) / icon.scale,
                        height: CGFloat(icon.image.height) / icon.scale
                    )
                    glyphs.append(HiddenBarGlyph(
                        key: item.key,
                        name: name,
                        image: NSImage(cgImage: icon.image, size: size),
                        size: size
                    ))
                } else {
                    glyphs.append(HiddenBarGlyph(
                        key: item.key,
                        name: name,
                        image: app.icon,
                        size: CGSize(width: 20, height: 20)
                    ))
                }
            }
        }
        return glyphs
    }

    private func activateHiddenItem(_ key: MenuBarItemKey) {
        guard settings.hiddenBarEnabled, hider.available,
              Set(settings.hiddenBarHiddenBundleIDs).contains(key.bundleID)
        else { return }
        let cachedItems = iconCache.resolvedSnapshot(for: key.bundleID)
        let cachedItem = cachedItems?.first { $0.key == key }
        let cachedIcons = iconCache.icons.filter { $0.key.bundleID == key.bundleID }
        guard let owner = Self.activationOwner(
            bundleID: key.bundleID,
            selectedItem: cachedItem,
            cachedItems: cachedItems,
            runningCandidates: runningAppsSnapshot().candidates
        ) else { return }
        suspendReconceal()
        guard temporarilyReveal(key.bundleID, ownerPID: owner.pid) else {
            cancelActivationIfInvalid(
                configured: Set(settings.hiddenBarHiddenBundleIDs),
                snapshot: runningAppsSnapshot()
            )
            if Self.shouldResumeReconcealAfterFailedReveal(
                hasTemporaryReveals: !temporarilyRevealed.isEmpty,
                activationInFlight: activationTask != nil
            ) {
                scheduleReconceal()
            }
            return
        }
        activationTask?.cancel()
        activationGeneration += 1
        let generation = activationGeneration
        let activation = ActiveActivation(bundleID: key.bundleID, pid: owner.pid, generation: generation)
        activeActivation = activation
        activationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let freshItems = await resolveRevealedItems(
                for: key.bundleID,
                owner: owner
            ) else {
                finishActivation(activation)
                return
            }
            guard activationIsValid(activation) else {
                cancelActivationIfCurrent(activation, removeReveal: true)
                return
            }
            let freshIcons = await HiddenBarIconCaptureService.captureVisible(
                freshItems,
                timeout: Self.captureDeadline
            )
            guard activationIsValid(activation) else {
                cancelActivationIfCurrent(activation, removeReveal: true)
                return
            }
            let target = Self.activationTarget(
                for: key,
                cachedItems: cachedItems,
                cachedIcons: cachedIcons,
                freshItems: freshItems,
                freshIcons: freshIcons
            )
            guard activationIsValid(activation) else {
                cancelActivationIfCurrent(activation, removeReveal: true)
                return
            }
            iconCache.replaceResolvedItems(
                [key.bundleID: freshItems],
                capturedIcons: freshIcons,
                replacingCapturedIcons: true
            )
            guard activationIsValid(activation) else {
                cancelActivationIfCurrent(activation, removeReveal: true)
                return
            }
            if let target {
                await forwarder.forward(to: target)
            }
            finishActivation(activation)
        }
    }

    nonisolated static func activationTarget(
        for key: MenuBarItemKey,
        cachedItems: [ResolvedMenuBarItem]?,
        cachedIcons: [MenuBarItemKey: CapturedIcon],
        freshItems: [ResolvedMenuBarItem],
        freshIcons: [MenuBarItemKey: CapturedIcon]
    ) -> ResolvedMenuBarItem? {
        guard let cachedItem = cachedItems?.first(where: { $0.key == key }) else { return nil }
        let cachedSameProcessItems = cachedItems?.filter { $0.pid == cachedItem.pid } ?? []
        let freshSameProcessItems = freshItems.filter { $0.pid == cachedItem.pid }
        if let semanticIdentity = cachedItem.semanticIdentity {
            guard cachedSameProcessItems.count(where: { $0.semanticIdentity == semanticIdentity }) == 1 else {
                return nil
            }
            let matches = freshSameProcessItems.filter { $0.semanticIdentity == semanticIdentity }
            return matches.count == 1 ? matches[0] : nil
        }
        guard let cachedIcon = cachedIcons[key] else { return nil }
        guard cachedSameProcessItems.allSatisfy({ cachedIcons[$0.key] != nil }),
              freshSameProcessItems.allSatisfy({ freshIcons[$0.key] != nil }),
              cachedSameProcessItems.count(where: { item in
                  guard let icon = cachedIcons[item.key] else { return false }
                  return HiddenBarIconCache.isVisuallyEqual(cachedIcon, icon)
              }) == 1
        else { return nil }
        let matches = freshSameProcessItems.filter { item in
            guard let freshIcon = freshIcons[item.key] else { return false }
            return HiddenBarIconCache.isVisuallyEqual(cachedIcon, freshIcon)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    nonisolated static func activationOwner(
        bundleID: String,
        selectedItem: ResolvedMenuBarItem?,
        cachedItems: [ResolvedMenuBarItem]?,
        runningCandidates: [MenuBarAppCandidate]
    ) -> HiddenBarActivationOwner? {
        let candidatePIDs = Set(
            runningCandidates.lazy
                .filter { $0.bundleID == bundleID }
                .map(\.pid)
        )
        if let selectedItem {
            guard selectedItem.key.bundleID == bundleID,
                  candidatePIDs.contains(selectedItem.pid)
            else { return nil }
            return HiddenBarActivationOwner(pid: selectedItem.pid, allowsAuthoritativeEmpty: true)
        }
        let cachedPIDs = Set(
            (cachedItems ?? []).lazy
                .filter { $0.key.bundleID == bundleID }
                .map(\.pid)
        )
        if !cachedPIDs.isEmpty {
            guard cachedPIDs.count == 1, let pid = cachedPIDs.first,
                  candidatePIDs.contains(pid)
            else { return nil }
            return HiddenBarActivationOwner(pid: pid, allowsAuthoritativeEmpty: true)
        }
        guard candidatePIDs.count == 1, let pid = candidatePIDs.first else { return nil }
        return HiddenBarActivationOwner(pid: pid, allowsAuthoritativeEmpty: false)
    }

    nonisolated static func shouldResumeReconcealAfterFailedReveal(
        hasTemporaryReveals: Bool,
        activationInFlight: Bool
    ) -> Bool {
        hasTemporaryReveals && !activationInFlight
    }

    nonisolated static func activationContextIsValid(
        bundleID: String,
        pid: pid_t,
        configuredBundleIDs: Set<String>,
        temporarilyRevealedBundleIDs: Set<String>,
        runningCandidates: [MenuBarAppCandidate]
    ) -> Bool {
        configuredBundleIDs.contains(bundleID)
            && temporarilyRevealedBundleIDs.contains(bundleID)
            && runningCandidates.contains { $0.bundleID == bundleID && $0.pid == pid }
    }

    private func resolveRevealedItems(
        for bundleID: String,
        owner: HiddenBarActivationOwner
    ) async -> [ResolvedMenuBarItem]? {
        let snapshot = runningAppsSnapshot()
        let candidates = snapshot.candidates.filter { $0.bundleID == bundleID && $0.pid == owner.pid }
        guard !candidates.isEmpty else { return nil }
        let resolution = await itemService.resolveItems(
            candidates: candidates,
            bundleIDs: [bundleID],
            allowEmptyBundleIDs: owner.allowsAuthoritativeEmpty ? [bundleID] : []
        )
        guard !Task.isCancelled, temporarilyRevealed.contains(bundleID),
              let items = resolution.itemsByBundleID[bundleID]
        else { return nil }
        return items
    }

    private func temporarilyReveal(_ bundleID: String, ownerPID: pid_t) -> Bool {
        guard settings.hiddenBarEnabled, hider.available else { return false }
        let hidden = Set(settings.hiddenBarHiddenBundleIDs)
        let snapshot = runningAppsSnapshot()
        guard hidden.contains(bundleID),
              snapshot.candidates.contains(where: { $0.bundleID == bundleID && $0.pid == ownerPID })
        else { return false }

        temporarilyRevealed.insert(bundleID)
        reconcileConcealment(
            snapshot: snapshot,
            captureBundleIDs: [],
            bypassHysteresis: true
        )
        guard !hider.conceals(bundleID) else {
            temporarilyRevealed.remove(bundleID)
            return false
        }
        return true
    }

    private func finishActivation(_ activation: ActiveActivation) {
        guard activationIsValid(activation) else {
            cancelActivationIfCurrent(activation, removeReveal: true)
            return
        }
        activeActivation = nil
        activationTask = nil
        if temporarilyRevealed.contains(activation.bundleID) {
            scheduleReconceal()
        }
    }

    private func activationIsValid(_ activation: ActiveActivation) -> Bool {
        guard !Task.isCancelled,
              activation.generation == activationGeneration,
              activeActivation == activation
        else { return false }
        return Self.activationContextIsValid(
            bundleID: activation.bundleID,
            pid: activation.pid,
            configuredBundleIDs: Set(settings.hiddenBarHiddenBundleIDs),
            temporarilyRevealedBundleIDs: temporarilyRevealed,
            runningCandidates: runningAppsSnapshot().candidates
        )
    }

    private func cancelActivationIfInvalid(configured: Set<String>, snapshot: RunningAppsSnapshot) {
        guard let activation = activeActivation,
              !Self.activationContextIsValid(
                  bundleID: activation.bundleID,
                  pid: activation.pid,
                  configuredBundleIDs: configured,
                  temporarilyRevealedBundleIDs: temporarilyRevealed,
                  runningCandidates: snapshot.candidates
              )
        else { return }
        cancelActivationIfCurrent(activation, removeReveal: true)
    }

    private func cancelActivationIfCurrent(_ activation: ActiveActivation, removeReveal: Bool) {
        guard activeActivation == activation else { return }
        if removeReveal {
            temporarilyRevealed.remove(activation.bundleID)
        }
        activationGeneration += 1
        activationTask?.cancel()
        activationTask = nil
        activeActivation = nil
        if !temporarilyRevealed.isEmpty {
            scheduleReconceal()
        }
    }

    private func suspendReconceal() {
        reconcealGeneration += 1
        reconcealTask?.cancel()
        reconcealTask = nil
    }

    private func scheduleReconceal() {
        reconcealTask?.cancel()
        reconcealGeneration += 1
        let generation = reconcealGeneration
        let interval = SettingsStore.validatedHiddenBarRehideIntervalSeconds(
            settings.hiddenBarRehideIntervalSeconds
        )
        let poll = Self.menuGuardPollInterval
        reconcealTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            var remaining = Duration.seconds(interval)
            var lastSample = clock.now
            var previousMenuOpen: Bool?
            while remaining > .zero, !Task.isCancelled {
                try? await Task.sleep(for: poll)
                guard !Task.isCancelled, generation == reconcealGeneration else { return }
                let ownerPIDs = menuOwnerPIDs(for: temporarilyRevealed)
                let menuOpen = await itemService.isMenuOpen(ownerPIDs: ownerPIDs)
                guard !Task.isCancelled, generation == reconcealGeneration else { return }
                let now = clock.now
                remaining = Self.rehideRemaining(
                    remaining: remaining,
                    elapsed: lastSample.duration(to: now),
                    previousMenuOpen: previousMenuOpen,
                    menuOpen: menuOpen
                )
                lastSample = now
                previousMenuOpen = menuOpen
            }
            guard !Task.isCancelled, generation == reconcealGeneration else { return }
            while !Task.isCancelled, generation == reconcealGeneration {
                let revealed = temporarilyRevealed
                guard !revealed.isEmpty else {
                    reconcealTask = nil
                    return
                }
                let ownerPIDs = menuOwnerPIDs(for: revealed)
                let menuOpenBeforeRefresh = await itemService.isMenuOpen(ownerPIDs: ownerPIDs)
                guard !Task.isCancelled, generation == reconcealGeneration else { return }
                if menuOpenBeforeRefresh != false {
                    try? await Task.sleep(for: poll)
                    continue
                }
                await refreshVisibleIcons(revealed)
                guard !Task.isCancelled, generation == reconcealGeneration else { return }
                let menuOpenAfterRefresh = await itemService.isMenuOpen(
                    ownerPIDs: menuOwnerPIDs(for: temporarilyRevealed)
                )
                guard !Task.isCancelled, generation == reconcealGeneration else { return }
                guard menuOpenAfterRefresh == false else { continue }
                temporarilyRevealed.subtract(revealed)
                applyConcealment(
                    runningBundleIDs: runningAppsSnapshot().bundleIDs,
                    bypassHysteresis: true
                )
                reconcealTask = nil
                return
            }
        }
    }

    private func clearTemporaryReveals() {
        reconcealGeneration += 1
        reconcealTask?.cancel()
        reconcealTask = nil
        activationGeneration += 1
        activationTask?.cancel()
        activationTask = nil
        activeActivation = nil
        temporarilyRevealed.removeAll()
    }

    private func cancelReconcealIfNoTemporaryReveals() {
        guard temporarilyRevealed.isEmpty, reconcealTask != nil else { return }
        reconcealGeneration += 1
        reconcealTask?.cancel()
        reconcealTask = nil
    }

    private struct RunningAppsSnapshot {
        let bundleIDs: Set<String>
        let candidates: [MenuBarAppCandidate]
    }

    private func runningAppsSnapshot() -> RunningAppsSnapshot {
        let applications = NSWorkspace.shared.runningApplications
        var bundleIDs: Set<String> = []
        var candidates: [MenuBarAppCandidate] = []
        bundleIDs.reserveCapacity(applications.count)
        candidates.reserveCapacity(applications.count)
        for app in applications {
            guard let bundleID = app.bundleIdentifier else { continue }
            bundleIDs.insert(bundleID)
            candidates.append(MenuBarAppCandidate(
                bundleID: bundleID,
                pid: app.processIdentifier,
                name: app.localizedName ?? bundleID
            ))
        }
        return RunningAppsSnapshot(bundleIDs: bundleIDs, candidates: candidates)
    }

    private func menuOwnerPIDs(for bundleIDs: Set<String>) -> Set<pid_t> {
        guard !bundleIDs.isEmpty else { return [] }
        return Set(NSWorkspace.shared.runningApplications.compactMap { app in
            app.bundleIdentifier.map(bundleIDs.contains) == true ? app.processIdentifier : nil
        })
    }

    nonisolated static func wantsRefresh(
        enabled: Bool,
        available: Bool,
        hiddenBundleIDs: Set<String>
    ) -> Bool {
        enabled && available && !hiddenBundleIDs.isEmpty
    }

    nonisolated static func effectiveHiddenBundleIDs(
        configured: Set<String>,
        temporarilyRevealed: Set<String>,
        pendingCapture: Set<String> = []
    ) -> Set<String> {
        configured.subtracting(temporarilyRevealed).subtracting(pendingCapture)
    }

    nonisolated static func rehideRemaining(
        remaining: Duration,
        elapsed: Duration,
        previousMenuOpen: Bool?,
        menuOpen: Bool?
    ) -> Duration {
        guard previousMenuOpen == false, menuOpen == false else { return remaining }
        return max(.zero, remaining - max(.zero, elapsed))
    }

    private func installDidBecomeActiveObserver() {
        guard didBecomeActiveObserver == nil else { return }
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hider.refreshAvailability()
                self?.reconcileRefreshTimer()
                self?.handleRefreshTick()
            }
        }
    }

    private func installRunningApplicationObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        if appLaunchObserver == nil {
            appLaunchObserver = notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundleID = app?.bundleIdentifier
                Task { @MainActor [weak self] in
                    self?.handleRunningApplicationChanged(bundleID: bundleID, terminated: false)
                }
            }
        }
        if appTerminationObserver == nil {
            appTerminationObserver = notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundleID = app?.bundleIdentifier
                Task { @MainActor [weak self] in
                    self?.handleRunningApplicationChanged(bundleID: bundleID, terminated: true)
                }
            }
        }
    }

    private func removeRunningApplicationObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        if let appLaunchObserver {
            notificationCenter.removeObserver(appLaunchObserver)
            self.appLaunchObserver = nil
        }
        if let appTerminationObserver {
            notificationCenter.removeObserver(appTerminationObserver)
            self.appTerminationObserver = nil
        }
    }

    private func handleRunningApplicationChanged(bundleID: String?, terminated: Bool) {
        let configured = Set(settings.hiddenBarHiddenBundleIDs)
        guard Self.wantsRefresh(
            enabled: settings.hiddenBarEnabled,
            available: hider.available,
            hiddenBundleIDs: configured
        ) else { return }

        if terminated, let bundleID {
            temporarilyRevealed.remove(bundleID)
        }

        let snapshot = runningAppsSnapshot()
        temporarilyRevealed.formIntersection(snapshot.bundleIDs)
        cancelActivationIfInvalid(configured: configured, snapshot: snapshot)
        cancelReconcealIfNoTemporaryReveals()
        iconCache.prune(keeping: configured.intersection(snapshot.bundleIDs))
        let captures: Set<String>
        if !terminated, let bundleID, configured.contains(bundleID) {
            captures = [bundleID]
        } else {
            captures = []
        }
        reconcileConcealment(snapshot: snapshot, captureBundleIDs: captures)
        refreshPanelIfVisible()
    }
}
