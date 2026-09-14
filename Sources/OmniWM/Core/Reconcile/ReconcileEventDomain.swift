// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

enum ReconcileEventDomain {
    case window
    case focus
    case viewport
    case session

    static func domain(for event: WMEvent) -> ReconcileEventDomain {
        switch event {
        case .windowAdmitted,
             .windowRekeyed,
             .windowRemoved,
             .workspaceAssigned,
             .windowModeChanged,
             .floatingGeometryUpdated,
             .floatingStateChanged,
             .manualLayoutOverrideChanged,
             .windowAdmissionHintsChanged,
             .topLevelInventoryObserved,
             .niriPlacementsResolved,
             .dwindlePlacementsResolved,
             .layoutOperationPerformed,
             .managedReplacementMetadataChanged,
             .hiddenApplicationsChanged,
             .appVisibilityInvalidated,
             .hiddenStateChanged,
             .nativeFullscreenTransition:
            .window
        case .focusLeaseChanged,
             .managedFocusRequested,
             .managedFocusConfirmed,
             .managedFocusCancelled,
             .nativeFocusOwnerChanged,
             .focusRemembered,
             .focusFallbackRemembered,
             .focusForgotten,
             .suppressedFocusChanged,
             .systemModalFocusChanged,
             .nativeFullscreenPlaceholderSelected,
             .interactionMonitorChanged,
             .workspaceFocusCleared:
            .focus
        case .viewportChanged,
             .viewportCommitted,
             .viewportForgotten,
             .selectionChanged:
            .viewport
        case .scratchpadMembershipChanged,
             .scratchpadRevealChanged,
             .visibleWorkspacesChanged,
             .spaceTopologyChanged,
             .topologyChanged,
             .activeSpaceChanged,
             .systemSleep,
             .systemWake,
             .userCommand:
            .session
        }
    }
}
