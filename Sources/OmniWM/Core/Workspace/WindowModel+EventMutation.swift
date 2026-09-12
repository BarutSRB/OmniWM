// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

extension WindowModel {
    func applyFieldMutation(_ event: WMEvent, monitors: [Monitor]) {
        switch event {
        case let .topLevelInventoryObserved(tokens, _):
            for token in tokens where entry(for: token)?.lifetimeAuthority == .directLifecycle {
                setLifetimeAuthority(.axTopLevelInventory, for: token)
            }

        case let .floatingGeometryUpdated(token, _, referenceMonitorId, frame, normalizedOrigin, restoreToFloating, _):
            setFloatingState(
                .init(
                    lastFrame: frame,
                    normalizedOrigin: normalizedOrigin,
                    referenceMonitorId: referenceMonitorId,
                    restoreToFloating: restoreToFloating
                ),
                for: token
            )

        case let .floatingStateChanged(token, _, state, _):
            setFloatingState(state, for: token)

        case let .manualLayoutOverrideChanged(token, _, layoutOverride, _):
            setManualLayoutOverride(layoutOverride, for: token)

        case let .niriPlacementsResolved(placements, _):
            applyNiriPlacements(placements, monitors: monitors)

        case let .dwindlePlacementsResolved(placements, _):
            applyDwindlePlacements(placements, monitors: monitors)

        case let .hiddenStateChanged(token, _, _, hiddenState, _):
            setHiddenState(hiddenState, for: token)

        case let .nativeFullscreenTransition(token, _, _, change, _):
            switch change {
            case let .suspended(reason):
                setLayoutReason(reason, for: token)
            case .restored:
                restoreFromNativeState(for: token)
            }

        case let .managedReplacementMetadataChanged(token, _, _, metadata, _):
            setManagedReplacementMetadata(metadata, for: token)

        default:
            preconditionFailure("Expected a WindowModel field mutation")
        }
    }
}
