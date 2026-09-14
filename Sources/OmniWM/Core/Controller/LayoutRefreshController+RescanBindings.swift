// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension LayoutRefreshController {
    func reconcileFullRescanBindings(
        context: FullRescanMutationContext
    ) {
        let controller = context.controller
        let scope = context.scope
        let enumerationSnapshot = context.enumerationSnapshot
        let retainedEntries = controller.workspaceManager.allEntries()
        let scopedBindingPIDs: Set<pid_t>? = switch scope {
        case .all:
            nil
        case let .targeted(appPIDs, _, _):
            Set(
                enumerationSnapshot.successfullyEnumeratedPIDs
                    .union(
                        controller.axManager.pendingManagedWindowBindingRetryPIDs(
                            intersecting: appPIDs
                        )
                    )
                    .filter { pid in
                        AppAXContextRegistry.contexts[pid] != nil
                            || retainedEntries.contains { $0.pid == pid }
                    }
            )
        }
        controller.axManager.reconcileManagedWindowBindings(
            retainedEntries,
            scopedPIDs: scopedBindingPIDs
        )
        controller.axEventHandler.pruneIdentityAliases(
            retainingWindowIds: Set(retainedEntries.map(\.windowId))
                .union(controller.axEventHandler.activeAdmissionRetryWindowIds)
                .union(controller.axEventHandler.admissionQuarantineByWindowId.keys)
        )
    }
}
