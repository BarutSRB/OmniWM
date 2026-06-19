// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct SpaceTopology: Equatable, Sendable {
    struct DisplaySpaces: Equatable, Sendable {
        var displayIdentifier: String
        var spaceIds: [UInt64]
        var currentSpaceId: UInt64
    }

    var displays: [DisplaySpaces] = []
    var activeSpaceId: UInt64 = 0
    var fullscreenSpaceIds: Set<UInt64> = []
    var windowSpace: [Int: UInt64] = [:]

    var isPopulated: Bool {
        !displays.isEmpty
    }

    func spaceForWindow(_ windowId: Int) -> UInt64? {
        windowSpace[windowId]
    }

    func isFullscreenSpace(_ spaceId: UInt64) -> Bool {
        fullscreenSpaceIds.contains(spaceId)
    }

    func isCurrentSpace(_ spaceId: UInt64) -> Bool {
        displays.contains { $0.currentSpaceId == spaceId }
    }

    func isKnownSpace(_ spaceId: UInt64) -> Bool {
        displays.contains { $0.currentSpaceId == spaceId || $0.spaceIds.contains(spaceId) }
    }

    func isWindowOnFullscreenSpace(_ windowId: Int) -> Bool {
        guard let spaceId = windowSpace[windowId] else { return false }
        return fullscreenSpaceIds.contains(spaceId)
    }

    func isWindowOnKnownInactiveSpace(_ windowId: Int) -> Bool {
        guard let spaceId = windowSpace[windowId] else { return false }
        return isKnownSpace(spaceId) && !isCurrentSpace(spaceId)
    }

    func selectWindowSpace(from candidates: [UInt64]) -> UInt64? {
        if let currentDesktop = candidates.first(where: { isCurrentSpace($0) && !isFullscreenSpace($0) }) {
            return currentDesktop
        }
        if let knownDesktop = candidates.first(where: { isKnownSpace($0) && !isFullscreenSpace($0) }) {
            return knownDesktop
        }
        if let current = candidates.first(where: { isCurrentSpace($0) }) {
            return current
        }
        return candidates.first { $0 != 0 }
    }
}
