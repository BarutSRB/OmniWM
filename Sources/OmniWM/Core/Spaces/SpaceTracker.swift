import Foundation

@MainActor
final class SpaceTracker {
    weak var controller: WMController?

    init(controller: WMController) {
        self.controller = controller
    }

    private var isEnabled: Bool {
        controller?.settings.spacesTrackingEnabled ?? false
    }

    func start() {
        refresh()
    }

    func refresh() {
        guard let controller, isEnabled else { return }
        let managed = SkyLight.shared.managedSpaces()
        guard !managed.isEmpty else { return }

        var topology = SpaceTopology()
        topology.displays = managed.map {
            SpaceTopology.DisplaySpaces(
                displayIdentifier: $0.displayIdentifier,
                spaceIds: $0.spaceIds,
                currentSpaceId: $0.currentSpaceId
            )
        }
        topology.fullscreenSpaceIds = managed.reduce(into: Set<UInt64>()) { $0.formUnion($1.fullscreenSpaceIds) }
        topology.activeSpaceId = SkyLight.shared.activeSpace() ?? 0
        for entry in controller.workspaceManager.allEntries() {
            let windowId = entry.windowId
            guard windowId > 0, let spaceId = SkyLight.shared.spaceForWindow(UInt32(windowId)) else { continue }
            topology.windowSpace[windowId] = spaceId
        }
        controller.workspaceManager.commitSpaceTopology(topology)
        controller.workspaceManager.reconcileNativeFullscreenWithTopology()
    }

    func noteWindowSpace(windowId: Int, spaceId: UInt64) {
        guard let controller, isEnabled, spaceId != 0 else { return }
        guard let entry = controller.workspaceManager.entry(forWindowId: windowId) else { return }
        var topology = controller.workspaceManager.spaceTopology
        if topology.activeSpaceId == 0 || !topology.isKnownSpace(spaceId) {
            topology = refreshedTopology(preserving: topology) ?? topology
        }
        topology.windowSpace[windowId] = spaceId
        controller.workspaceManager.commitSpaceTopology(topology)
        controller.workspaceManager.reconcileNativeFullscreenWithTopology(for: entry.token)
    }

    func noteWindowDestroyed(windowId: Int) {
        guard let controller, isEnabled else { return }
        var topology = controller.workspaceManager.spaceTopology
        guard topology.windowSpace.removeValue(forKey: windowId) != nil else { return }
        controller.workspaceManager.commitSpaceTopology(topology)
    }

    private func refreshedTopology(preserving topology: SpaceTopology) -> SpaceTopology? {
        let managed = SkyLight.shared.managedSpaces()
        guard !managed.isEmpty else { return nil }

        var refreshed = topology
        refreshed.displays = managed.map {
            SpaceTopology.DisplaySpaces(
                displayIdentifier: $0.displayIdentifier,
                spaceIds: $0.spaceIds,
                currentSpaceId: $0.currentSpaceId
            )
        }
        refreshed.fullscreenSpaceIds = managed.reduce(into: Set<UInt64>()) {
            $0.formUnion($1.fullscreenSpaceIds)
        }
        refreshed.activeSpaceId = SkyLight.shared.activeSpace() ?? topology.activeSpaceId
        return refreshed
    }
}
