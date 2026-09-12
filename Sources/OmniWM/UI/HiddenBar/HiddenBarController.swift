// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

@MainActor
final class HiddenBarController {
    private struct ActiveActivation: Equatable {
        let bundleID: String
        let pid: pid_t
        let generation: Int
    }

    let statusItems: HiddenBarStatusItems
    let observation = HiddenBarObservation()
    let capture: HiddenBarCaptureSession
    let reconcealment: HiddenBarReconcealment
    private let settings: SettingsStore
    private let hider = AssessmentModeHider()
    private let itemService: MenuBarItemService
    private let panel = HiddenBarPanelController()
    private let iconCache = HiddenBarIconCache()
    private let forwarder: HiddenBarClickForwarder

    private var activationTask: Task<Void, Never>?
    private var activationGeneration = 0
    private var activeActivation: ActiveActivation?
    private var temporarilyRevealed: Set<String> = []
    let performance = HiddenBarPerformanceCapture()

    init(settings: SettingsStore) {
        self.settings = settings
        let itemService = MenuBarItemService()
        self.itemService = itemService
        forwarder = HiddenBarClickForwarder(itemService: itemService)
        statusItems = HiddenBarStatusItems(hider: hider)
        capture = HiddenBarCaptureSession(itemService: itemService, iconCache: iconCache)
        reconcealment = HiddenBarReconcealment(itemService: itemService, performance: performance)
        capture.connect(controller: self)
        reconcealment.connect(controller: self)
        observation.connect(controller: self)
        panel.onActivate = { [weak self] key in
            self?.activateHiddenItem(key)
        }
        iconCache.onChange = { [weak self] in
            self?.refreshPanelIfVisible()
        }
        hider.onConcealingChanged = { [weak self] concealing in
            self?.statusItems.handleConcealingChanged(concealing)
        }
        statusItems.setClickHandler { [weak self] event, anchor in
            self?.statusItems.onFallbackIconClick?(event, anchor)
        }
        panel.isExemptWindow = { [weak self] window in
            self?.statusItems.ownsStatusItemWindow(window) == true
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
        let snapshot = HiddenBarRunningAppsSnapshot.current()
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

    func setup() {
        observation.start()
        itemService.start()
        observation.install()
        applySettings()
    }

    func applySettings() {
        hider.refreshAvailability()
        capture.cancel()
        let normalizedBundleIDs = HiddenBarSettingsPolicy.normalizedBundleIDs(
            settings.hiddenBar.hiddenBundleIDs,
            additionalProtectedBundleIDs: [Bundle.main.bundleIdentifier ?? "com.barut.OmniWM"]
        )
        if settings.hiddenBar.hiddenBundleIDs != normalizedBundleIDs {
            settings.hiddenBar.hiddenBundleIDs = normalizedBundleIDs
        }
        let configured = Set(normalizedBundleIDs)
        temporarilyRevealed.formIntersection(configured)

        guard HiddenBarConcealmentPolicy.wantsRefresh(
            enabled: settings.hiddenBar.enabled,
            available: hider.available,
            hiddenBundleIDs: configured
        ) else {
            observation.cancelTopologyRefresh()
            clearTemporaryReveals()
            hider.drop()
            panel.dismiss()
            iconCache.prune(keeping: [])
            return
        }

        let snapshot = HiddenBarRunningAppsSnapshot.current()
        temporarilyRevealed.formIntersection(snapshot.bundleIDs)
        cancelActivationIfInvalid(configured: configured, snapshot: snapshot)
        cancelReconcealIfNoTemporaryReveals()
        let hiddenRunning = configured.intersection(snapshot.bundleIDs)
        iconCache.prune(keeping: hiddenRunning)
        let unresolved = hiddenRunning.filter { !iconCache.hasResolvedItems(for: $0) }
        capture.reconcile(snapshot: snapshot, captureBundleIDs: Set(unresolved))
        refreshPanelIfVisible()
        statusItems.syncFallbackIcon()
    }

    func setEnabled(_ enabled: Bool) {
        settings.hiddenBar.enabled = enabled
        applySettings()
    }

    func togglePanel(placement: HiddenBarPanelPlacement?) {
        guard settings.hiddenBar.enabled, hider.available, let placement else { return }
        if panel.isVisible {
            panel.dismiss()
            return
        }
        refreshItems()
        panel.toggle(placement: placement, items: HiddenBarGlyphProjection.current(
            bundleIDs: settings.hiddenBar.hiddenBundleIDs, iconCache: iconCache, hider: hider
        ))
    }

    func dismissPanel() {
        panel.dismiss()
    }

    func refreshPanelIfVisible() {
        guard panel.isVisible else { return }
        panel.refresh(items: HiddenBarGlyphProjection.current(
            bundleIDs: settings.hiddenBar.hiddenBundleIDs, iconCache: iconCache, hider: hider
        ))
    }

    func cleanup() {
        observation.invalidate()
        capture.cancel()
        forwarder.cancel()
        clearTemporaryReveals()
        panel.dismiss()
        statusItems.dismiss()
        observation.removeObservers()
        hider.drop()
        itemService.stop()
    }

    var isConcealing: Bool {
        hider.isConcealing
    }

    func refreshAvailabilityAndItems() {
        hider.refreshAvailability()
        refreshItems()
    }

    func refreshItems() {
        performance.recordRefresh()
        statusItems.syncFallbackIcon()
        let configured = Set(settings.hiddenBar.hiddenBundleIDs)
        guard HiddenBarConcealmentPolicy.wantsRefresh(
            enabled: settings.hiddenBar.enabled,
            available: hider.available,
            hiddenBundleIDs: configured
        ) else { return }
        let snapshot = HiddenBarRunningAppsSnapshot.current()
        iconCache.prune(keeping: configured.intersection(snapshot.bundleIDs))
        capture.reconcile(snapshot: snapshot, captureBundleIDs: [])
    }

    var configuredHiddenBundleIDs: Set<String> {
        Set(settings.hiddenBar.hiddenBundleIDs)
    }

    var revealedBundleIDs: Set<String> {
        temporarilyRevealed
    }

    var captureEligibleBundleIDs: Set<String> {
        HiddenBarConcealmentPolicy.effectiveHiddenBundleIDs(
            configured: configuredHiddenBundleIDs,
            temporarilyRevealed: temporarilyRevealed
        )
    }

    func applyConcealment(
        runningBundleIDs: Set<String>,
        bypassHysteresis: Bool = false
    ) {
        let configured = Set(settings.hiddenBar.hiddenBundleIDs)
        guard HiddenBarConcealmentPolicy.wantsRefresh(
            enabled: settings.hiddenBar.enabled,
            available: hider.available,
            hiddenBundleIDs: configured
        ) else { return }
        hider.apply(
            hiddenBundleIDs: HiddenBarConcealmentPolicy.effectiveHiddenBundleIDs(
                configured: configured,
                temporarilyRevealed: temporarilyRevealed,
                pendingCapture: capture.bundleIDs
            ),
            runningBundleIDs: runningBundleIDs,
            bypassHysteresis: bypassHysteresis
        )
    }
}

extension HiddenBarController {
    private func activateHiddenItem(_ key: MenuBarItemKey) {
        guard settings.hiddenBar.enabled, hider.available,
              Set(settings.hiddenBar.hiddenBundleIDs).contains(key.bundleID)
        else { return }
        let cachedItems = iconCache.resolvedSnapshot(for: key.bundleID)
        let cachedItem = cachedItems?.first { $0.key == key }
        let cachedIcons = iconCache.icons.filter { $0.key.bundleID == key.bundleID }
        guard let owner = HiddenBarActivationPolicy.activationOwner(
            bundleID: key.bundleID,
            selectedItem: cachedItem,
            cachedItems: cachedItems,
            runningCandidates: HiddenBarRunningAppsSnapshot.current().candidates
        ) else { return }
        reconcealment.cancel(reason: .cancelled)
        guard temporarilyReveal(key.bundleID, ownerPID: owner.pid) else {
            cancelActivationIfInvalid(
                configured: Set(settings.hiddenBar.hiddenBundleIDs),
                snapshot: HiddenBarRunningAppsSnapshot.current()
            )
            if HiddenBarActivationPolicy.shouldResumeReconcealAfterFailedReveal(
                hasTemporaryReveals: !temporarilyRevealed.isEmpty,
                activationInFlight: activationTask != nil
            ) {
                reconcealment.schedule(intervalSeconds: settings.hiddenBar.rehideIntervalSeconds)
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
            await resolveAndActivate(
                activation,
                key: key,
                owner: owner,
                cachedItems: cachedItems,
                cachedIcons: cachedIcons
            )
        }
    }

    private func resolveAndActivate(
        _ activation: ActiveActivation,
        key: MenuBarItemKey,
        owner: HiddenBarActivationOwner,
        cachedItems: [ResolvedMenuBarItem]?,
        cachedIcons: [MenuBarItemKey: CapturedIcon]
    ) async {
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
            timeout: HiddenBarIconCaptureService.captureDeadline
        )
        guard activationIsValid(activation) else {
            cancelActivationIfCurrent(activation, removeReveal: true)
            return
        }
        let target = HiddenBarActivationPolicy.activationTarget(
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

    private func resolveRevealedItems(
        for bundleID: String,
        owner: HiddenBarActivationOwner
    ) async -> [ResolvedMenuBarItem]? {
        let snapshot = HiddenBarRunningAppsSnapshot.current()
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
        guard settings.hiddenBar.enabled, hider.available else { return false }
        let hidden = Set(settings.hiddenBar.hiddenBundleIDs)
        let snapshot = HiddenBarRunningAppsSnapshot.current()
        guard hidden.contains(bundleID),
              snapshot.candidates.contains(where: { $0.bundleID == bundleID && $0.pid == ownerPID })
        else { return false }

        temporarilyRevealed.insert(bundleID)
        capture.reconcile(
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
            reconcealment.schedule(intervalSeconds: settings.hiddenBar.rehideIntervalSeconds)
        }
    }

    private func activationIsValid(_ activation: ActiveActivation) -> Bool {
        guard !Task.isCancelled,
              activation.generation == activationGeneration,
              activeActivation == activation
        else { return false }
        return HiddenBarActivationPolicy.activationContextIsValid(
            bundleID: activation.bundleID,
            pid: activation.pid,
            configuredBundleIDs: Set(settings.hiddenBar.hiddenBundleIDs),
            temporarilyRevealedBundleIDs: temporarilyRevealed,
            runningCandidates: HiddenBarRunningAppsSnapshot.current().candidates
        )
    }

    private func cancelActivationIfInvalid(configured: Set<String>, snapshot: HiddenBarRunningAppsSnapshot) {
        guard let activation = activeActivation,
              !HiddenBarActivationPolicy.activationContextIsValid(
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
            reconcealment.schedule(intervalSeconds: settings.hiddenBar.rehideIntervalSeconds)
        }
    }

    private func clearTemporaryReveals() {
        reconcealment.cancel(reason: .cancelled)
        activationGeneration += 1
        activationTask?.cancel()
        activationTask = nil
        activeActivation = nil
        temporarilyRevealed.removeAll()
    }

    private func cancelReconcealIfNoTemporaryReveals() {
        guard temporarilyRevealed.isEmpty else { return }
        reconcealment.cancelIfRunning(reason: .noRevealedItems)
    }

    func concealRevealed(_ bundleIDs: Set<String>) {
        temporarilyRevealed.subtract(bundleIDs)
        applyConcealment(
            runningBundleIDs: HiddenBarRunningAppsSnapshot.current().bundleIDs,
            bypassHysteresis: true
        )
    }

    func concealAllRevealed() {
        temporarilyRevealed.removeAll(keepingCapacity: true)
        applyConcealment(
            runningBundleIDs: HiddenBarRunningAppsSnapshot.current().bundleIDs,
            bypassHysteresis: true
        )
    }

    func startReconcealForTests(revealedBundleIDs: Set<String>) {
        temporarilyRevealed = revealedBundleIDs
        reconcealment.schedule(intervalSeconds: settings.hiddenBar.rehideIntervalSeconds)
    }

    var temporarilyRevealedBundleIDsForTests: Set<String> {
        temporarilyRevealed
    }

    func handleRunningApplicationChanged(bundleID: String?, terminated: Bool) {
        let configured = Set(settings.hiddenBar.hiddenBundleIDs)
        guard HiddenBarConcealmentPolicy.wantsRefresh(
            enabled: settings.hiddenBar.enabled,
            available: hider.available,
            hiddenBundleIDs: configured
        ) else { return }

        if terminated, let bundleID {
            temporarilyRevealed.remove(bundleID)
        }

        let snapshot = HiddenBarRunningAppsSnapshot.current()
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
        capture.reconcile(snapshot: snapshot, captureBundleIDs: captures)
        refreshPanelIfVisible()
    }
}
