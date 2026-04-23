// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation

enum SurfaceKind: String, Equatable {
    case border
    case workspaceBar
    case overview
    case utility
    case quake
}

enum HitTestPolicy: Equatable {
    case interactive
    case passthrough
}

enum CapturePolicy: Equatable {
    case included
    case excluded
}

struct SurfacePolicy: Equatable {
    let kind: SurfaceKind
    let hitTestPolicy: HitTestPolicy
    let capturePolicy: CapturePolicy
    let suppressesManagedFocusRecovery: Bool
}

@MainActor
final class SurfaceScene {
    struct SurfaceNode {
        let id: String
        let policy: SurfacePolicy
        weak var window: NSWindow?
        var windowNumber: Int?
        var frameProvider: (@MainActor () -> CGRect?)?
        var visibilityProvider: (@MainActor () -> Bool)?
    }

    private var nodesByID: [String: SurfaceNode] = [:]
    private var windowIDByObject: [ObjectIdentifier: String] = [:]
    private var surfaceIDsByWindowNumber: [Int: Set<String>] = [:]
    private var interactiveCandidateIds: Set<String> = []

    func register(window: NSWindow, node: SurfaceNode) {
        if let existingId = windowIDByObject[ObjectIdentifier(window)], existingId != node.id {
            unregister(id: existingId)
        }

        var node = node
        node.window = window
        if window.windowNumber > 0 {
            node.windowNumber = window.windowNumber
        }
        nodesByID[node.id] = node
        windowIDByObject[ObjectIdentifier(window)] = node.id
        if let windowNumber = node.windowNumber, windowNumber > 0 {
            surfaceIDsByWindowNumber[windowNumber, default: []].insert(node.id)
        }
        updateInteractiveCandidate(for: node)
    }

    func registerWindowNumber(node: SurfaceNode) {
        unregister(id: node.id)
        nodesByID[node.id] = node
        if let windowNumber = node.windowNumber, windowNumber > 0 {
            surfaceIDsByWindowNumber[windowNumber, default: []].insert(node.id)
        }
        updateInteractiveCandidate(for: node)
    }

    func unregister(window: NSWindow) {
        unregister(id: windowIDByObject[ObjectIdentifier(window)])
    }

    func unregister(id: String?) {
        guard let id, let node = nodesByID.removeValue(forKey: id) else { return }
        if let window = node.window {
            windowIDByObject.removeValue(forKey: ObjectIdentifier(window))
        }
        if let windowNumber = node.windowNumber, windowNumber > 0 {
            var ids = surfaceIDsByWindowNumber[windowNumber] ?? []
            ids.remove(id)
            if ids.isEmpty {
                surfaceIDsByWindowNumber.removeValue(forKey: windowNumber)
            } else {
                surfaceIDsByWindowNumber[windowNumber] = ids
            }
        }
        interactiveCandidateIds.remove(id)
    }

    private func updateInteractiveCandidate(for node: SurfaceNode) {
        if node.policy.hitTestPolicy == .interactive {
            interactiveCandidateIds.insert(node.id)
        } else {
            interactiveCandidateIds.remove(node.id)
        }
    }

    func contains(window: NSWindow?) -> Bool {
        guard let window else { return false }
        return windowIDByObject[ObjectIdentifier(window)] != nil
    }

    func contains(windowNumber: Int) -> Bool {
        guard windowNumber > 0 else { return false }
        return !(surfaceIDsByWindowNumber[windowNumber] ?? []).isEmpty
    }

    func containsInteractive(point: CGPoint) -> Bool {
        for id in interactiveCandidateIds {
            guard let node = nodesByID[id] else { continue }
            guard isVisible(node) else { continue }
            if resolvedFrame(for: node)?.contains(point) == true {
                return true
            }
        }
        return false
    }

    var hasFrontmostSuppressingWindow: Bool {
        guard let app = NSApp else { return false }
        let frontmostWindows = [app.keyWindow, app.mainWindow].compactMap { $0 }
        return frontmostWindows.contains { window in
            guard let node = node(for: window) else { return false }
            return node.policy.suppressesManagedFocusRecovery && isVisible(node)
        }
    }

    var hasVisibleSuppressingWindow: Bool {
        visibleNodes.contains { $0.policy.suppressesManagedFocusRecovery }
    }

    func isCaptureEligible(windowNumber: Int) -> Bool {
        guard windowNumber > 0 else { return false }
        guard let ids = surfaceIDsByWindowNumber[windowNumber], !ids.isEmpty else { return true }
        return !ids.compactMap({ nodesByID[$0] }).contains { $0.policy.capturePolicy == .excluded }
    }

    func visibleSurfaceIDs(
        kind: SurfaceKind? = nil,
        capturePolicy: CapturePolicy? = nil,
        suppressesManagedFocusRecovery: Bool? = nil
    ) -> [String] {
        matchingVisibleNodes(
            kind: kind,
            capturePolicy: capturePolicy,
            suppressesManagedFocusRecovery: suppressesManagedFocusRecovery
        )
            .map(\.id)
            .sorted()
    }

    func visibleWindows(
        kind: SurfaceKind? = nil,
        capturePolicy: CapturePolicy? = nil,
        suppressesManagedFocusRecovery: Bool? = nil
    ) -> [NSWindow] {
        matchingVisibleNodes(
            kind: kind,
            capturePolicy: capturePolicy,
            suppressesManagedFocusRecovery: suppressesManagedFocusRecovery
        )
        .compactMap(\.window)
        .sorted { lhs, rhs in
            lhs.windowNumber < rhs.windowNumber
        }
    }

    func reset() {
        nodesByID.removeAll()
        windowIDByObject.removeAll()
        surfaceIDsByWindowNumber.removeAll()
        interactiveCandidateIds.removeAll()
    }

    private func node(for window: NSWindow) -> SurfaceNode? {
        guard let id = windowIDByObject[ObjectIdentifier(window)] else { return nil }
        return nodesByID[id]
    }

    private var visibleNodes: [SurfaceNode] {
        nodesByID.values.filter(isVisible)
    }

    private func matchingVisibleNodes(
        kind: SurfaceKind?,
        capturePolicy: CapturePolicy?,
        suppressesManagedFocusRecovery: Bool?
    ) -> [SurfaceNode] {
        visibleNodes.filter { node in
            guard kind.map({ $0 == node.policy.kind }) ?? true else { return false }
            guard capturePolicy.map({ $0 == node.policy.capturePolicy }) ?? true else { return false }
            guard suppressesManagedFocusRecovery.map({ $0 == node.policy.suppressesManagedFocusRecovery }) ?? true else {
                return false
            }
            return true
        }
    }

    private func isVisible(_ node: SurfaceNode) -> Bool {
        if let visibilityProvider = node.visibilityProvider {
            return visibilityProvider()
        }
        if let window = node.window {
            return window.isVisible
        }
        return node.windowNumber != nil
    }

    private func resolvedFrame(for node: SurfaceNode) -> CGRect? {
        if let frameProvider = node.frameProvider {
            return frameProvider()
        }
        return node.window?.frame
    }
}
