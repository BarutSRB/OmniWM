// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation

extension AXEventHandler {
    func isAdmissionQuarantined(windowId: Int, axRef: AXWindowRef) -> Bool {
        guard let quarantine = admissionQuarantineByWindowId[windowId] else { return false }
        guard CFEqual(quarantine.axRef.element, axRef.element)
            || isKnownAXIdentityAlias(windowId: windowId, axRef: axRef)
        else {
            admissionQuarantineByWindowId.removeValue(forKey: windowId)
            identityAliasesByWindowId.removeValue(forKey: windowId)
            return false
        }
        return true
    }

    func resolveFullRescanIdentity(
        axRef: AXWindowRef,
        pid: pid_t,
        windowId: Int,
        observedAliases: FullRescanWindowIdentityAliases?,
        failedPIDs: Set<pid_t> = []
    ) -> FullRescanIdentityResolution {
        guard let controller,
              let existingEntry = controller.workspaceManager.entry(forWindowId: windowId)
        else {
            return .process(nil)
        }
        let isSameElement = CFEqual(existingEntry.axRef.element, axRef.element)
        let isKnownAlias = isKnownAXIdentityAlias(windowId: windowId, axRef: axRef)
            || observedAliases?.axRefs.contains(where: {
                CFEqual($0.element, existingEntry.axRef.element)
            }) == true
        guard isSameElement || isKnownAlias else {
            if failedPIDs.contains(existingEntry.pid) {
                return .preserve(existingEntry.token)
            }
            discardStaleManagedWindowIncarnation(existingEntry)
            return .process(nil)
        }
        let token = WindowToken(pid: pid, windowId: windowId)
        if existingEntry.token == token {
            guard !isSameElement else { return .process(existingEntry) }
            guard let windowId = UInt32(exactly: windowId),
                  let updatedEntry = rekeyManagedWindowIdentity(
                      from: token,
                      to: token,
                      windowId: windowId,
                      axRef: axRef
                  )
            else {
                return .preserve(existingEntry.token)
            }
            return .process(updatedEntry)
        }
        guard let windowId = UInt32(exactly: windowId),
              let rekeyedEntry = rekeyManagedWindowIdentity(
                  from: existingEntry.token,
                  to: token,
                  windowId: windowId,
                  axRef: axRef
              )
        else {
            return .preserve(existingEntry.token)
        }
        return .process(rekeyedEntry)
    }

    func updateIdentityAliases(
        _ aliasesByWindowId: [Int: FullRescanWindowIdentityAliases]
    ) {
        for (windowId, observedAliases) in aliasesByWindowId {
            var history = identityAliasesByWindowId[windowId] ?? .init()
            history.commit(observedAliases)
            identityAliasesByWindowId[windowId] = history
        }
    }

    func pruneIdentityAliases(retainingWindowIds: Set<Int>) {
        identityAliasesByWindowId = identityAliasesByWindowId.filter {
            retainingWindowIds.contains($0.key)
        }
    }

    func managedWindowToken(_ token: WindowToken, matchesObservedPid pid: pid_t) -> Bool {
        if token.pid == pid { return true }
        guard let entry = controller?.workspaceManager.entry(for: token) else { return false }
        if AXWindowService.processIdentifier(entry.axRef) == pid { return true }
        if identityAliasesByWindowId[token.windowId]?.contains(pid: pid) == true { return true }
        guard let windowId = UInt32(exactly: token.windowId) else { return false }
        return windowInfoProvider(windowId)?.pid == pid
    }

    func isKnownAXIdentityAlias(windowId: Int, axRef: AXWindowRef) -> Bool {
        identityAliasesByWindowId[windowId]?.contains(axRef) == true
    }

    func canonicalObservedWindowToken(pid: pid_t, axRef: AXWindowRef) -> WindowToken {
        if let existingEntry = controller?.workspaceManager.entry(forWindowId: axRef.windowId) {
            let matchesElement = CFEqual(existingEntry.axRef.element, axRef.element)
            if matchesElement || isKnownAXIdentityAlias(windowId: axRef.windowId, axRef: axRef) {
                return existingEntry.token
            }
        }
        return WindowToken(pid: pid, windowId: axRef.windowId)
    }

    func focusedWindowToken(for pid: pid_t) -> WindowToken? {
        guard let axRef = resolveFocusedAXWindowRef(pid: pid) else { return nil }
        return canonicalObservedWindowToken(pid: pid, axRef: axRef)
    }

    func isCurrentAXIncarnation(windowId: Int, axRef: AXWindowRef) -> Bool {
        if let entry = controller?.workspaceManager.entry(forWindowId: windowId) {
            return CFEqual(entry.axRef.element, axRef.element)
        }
        if let admissionWindowId = UInt32(exactly: windowId),
           let retryState = admissionRetryStateByWindowId[admissionWindowId]
        {
            guard let retryAXRef = retryState.axRef else { return false }
            return CFEqual(retryAXRef.element, axRef.element)
        }
        if let quarantine = admissionQuarantineByWindowId[windowId] {
            return CFEqual(quarantine.axRef.element, axRef.element)
        }
        if let admissionWindowId = UInt32(exactly: windowId),
           deferredCreatedWindowIds.contains(admissionWindowId)
        {
            return false
        }
        if let admissionWindowId = UInt32(exactly: windowId),
           createPlacementContextsByWindowId[admissionWindowId] != nil
        {
            return false
        }
        return true
    }

    private func resolveFocusedWindowValue(pid: pid_t) -> CFTypeRef? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )
        guard result == .success else { return nil }
        return focusedWindow
    }

    private func resolveFocusedAXWindowRef(pid: pid_t) -> AXWindowRef? {
        guard let windowElement = resolveFocusedWindowValue(pid: pid),
              CFGetTypeID(windowElement) == AXUIElementGetTypeID()
        else {
            return nil
        }
        let axElement = unsafeDowncast(windowElement, to: AXUIElement.self)
        return try? AXWindowRef(element: axElement)
    }
}
