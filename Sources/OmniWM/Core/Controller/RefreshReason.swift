// SPDX-License-Identifier: GPL-2.0-only
import Foundation

enum RelayoutSchedulingPolicy: Equatable, Sendable {
    case plain
    case debounced(nanoseconds: UInt64, dropWhileBusy: Bool)

    var debounceInterval: UInt64 {
        switch self {
        case .plain:
            0
        case let .debounced(nanoseconds, _):
            nanoseconds
        }
    }

    var shouldDropWhileBusy: Bool {
        switch self {
        case .plain:
            false
        case let .debounced(_, dropWhileBusy):
            dropWhileBusy
        }
    }
}

enum RefreshRequestRoute: Equatable, Sendable {
    case fullRescan
    case relayout
    case immediateRelayout
    case visibilityRefresh
    case windowRemoval
}

enum RefreshReason: String, Sendable {
    case startup
    case appLaunched
    case unlock
    case activeSpaceChanged
    case monitorConfigurationChanged
    case appRulesChanged
    case workspaceConfigChanged
    case layoutConfigChanged
    case monitorSettingsChanged
    case gapsChanged
    case workspaceTransition
    case appActivationTransition
    case workspaceLayoutToggled
    case appTerminated
    case windowRuleReevaluation
    case layoutCommand
    case interactiveGesture
    case axWindowCreated
    case axWindowChanged
    case windowDestroyed
    case appHidden
    case appUnhidden
    case overviewMutation

    var requestRoute: RefreshRequestRoute {
        switch self {
        case .startup,
             .appLaunched,
             .unlock,
             .activeSpaceChanged,
             .monitorConfigurationChanged,
             .appRulesChanged,
             .workspaceConfigChanged,
             .appTerminated:
            .fullRescan
        case .layoutConfigChanged,
             .monitorSettingsChanged,
             .gapsChanged,
             .workspaceLayoutToggled,
             .windowRuleReevaluation,
             .axWindowCreated,
             .axWindowChanged:
            .relayout
        case .workspaceTransition,
             .appActivationTransition,
             .layoutCommand,
             .interactiveGesture,
             .overviewMutation:
            .immediateRelayout
        case .appHidden,
             .appUnhidden:
            .visibilityRefresh
        case .windowDestroyed:
            .windowRemoval
        }
    }

    var relayoutSchedulingPolicy: RelayoutSchedulingPolicy {
        switch self {
        case .startup,
             .appLaunched,
             .unlock,
             .activeSpaceChanged,
             .monitorConfigurationChanged,
             .appRulesChanged,
             .workspaceConfigChanged,
             .layoutConfigChanged,
             .monitorSettingsChanged,
             .gapsChanged,
             .workspaceTransition,
             .appActivationTransition,
             .workspaceLayoutToggled,
             .appTerminated,
             .windowRuleReevaluation,
             .layoutCommand,
             .interactiveGesture,
             .appHidden,
             .appUnhidden,
             .overviewMutation:
            .plain
        case .axWindowCreated:
            .debounced(nanoseconds: 4_000_000, dropWhileBusy: false)
        case .axWindowChanged:
            .debounced(nanoseconds: 8_000_000, dropWhileBusy: true)
        case .windowDestroyed:
            .plain
        }
    }
}
