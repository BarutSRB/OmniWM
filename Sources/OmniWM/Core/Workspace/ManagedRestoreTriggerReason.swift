// SPDX-License-Identifier: GPL-2.0-only
import Foundation

enum ManagedRestoreTriggerReason: String, CaseIterable, Hashable, Sendable {
    case frameConfirmed = "frame_confirmed"
    case topologyChanged = "topology_changed"
    case workspaceMoved = "workspace_moved"
    case niriStateChanged = "niri_state_changed"
    case replacementRekeyed = "replacement_rekeyed"
}
