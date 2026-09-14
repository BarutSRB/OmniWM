// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import OmniWMIPC

enum SizingAction: Equatable, Hashable {
    case cycleSizeForward
    case cycleSizeBackward
    case cycleWindowPrimarySpanForward
    case cycleWindowPrimarySpanBackward
    case cycleWindowSecondarySpanForward
    case cycleWindowSecondarySpanBackward
    case toggleContainerFullPrimarySpan
    case expandContainerToAvailablePrimarySpan
    case resetWindowSecondarySpan
    case setContainerPrimarySpan(NiriSizeChange)
    case setWindowPrimarySpan(NiriSizeChange)
    case setWindowSecondarySpan(NiriSizeChange)
    case balanceSizes
}

extension SizingAction {
    func actionDisplayName() -> String {
        switch self {
        case .cycleSizeForward: "Cycle Size Forward"
        case .cycleSizeBackward: "Cycle Size Backward"
        case .cycleWindowPrimarySpanForward: "Cycle Window Primary Span Forward"
        case .cycleWindowPrimarySpanBackward: "Cycle Window Primary Span Backward"
        case .cycleWindowSecondarySpanForward: "Cycle Window Secondary Span Forward"
        case .cycleWindowSecondarySpanBackward: "Cycle Window Secondary Span Backward"
        case .toggleContainerFullPrimarySpan: "Toggle Container Full Primary Span"
        case .expandContainerToAvailablePrimarySpan: "Expand Container to Available Primary Span"
        case .resetWindowSecondarySpan: "Reset Window Secondary Span"
        case let .setContainerPrimarySpan(change): "Set Container Primary Span \(Self.sizeChangeDisplayName(change))"
        case let .setWindowPrimarySpan(change): "Set Window Primary Span \(Self.sizeChangeDisplayName(change))"
        case let .setWindowSecondarySpan(change): "Set Window Secondary Span \(Self.sizeChangeDisplayName(change))"
        case .balanceSizes: "Balance Sizes"
        }
    }

    func ipcCommandName() -> IPCCommandName? {
        switch self {
        case .cycleSizeForward:
            .sizing(.cycleSizeForward)
        case .cycleSizeBackward:
            .sizing(.cycleSizeBackward)
        case .cycleWindowPrimarySpanForward:
            .sizing(.cycleWindowPrimarySpanForward)
        case .cycleWindowPrimarySpanBackward:
            .sizing(.cycleWindowPrimarySpanBackward)
        case .cycleWindowSecondarySpanForward:
            .sizing(.cycleWindowSecondarySpanForward)
        case .cycleWindowSecondarySpanBackward:
            .sizing(.cycleWindowSecondarySpanBackward)
        case .toggleContainerFullPrimarySpan:
            .sizing(.toggleContainerFullPrimarySpan)
        case .expandContainerToAvailablePrimarySpan:
            .sizing(.expandContainerToAvailablePrimarySpan)
        case .resetWindowSecondarySpan:
            .sizing(.resetWindowSecondarySpan)
        case .setContainerPrimarySpan:
            .sizing(.setContainerPrimarySpan)
        case .setWindowPrimarySpan:
            .sizing(.setWindowPrimarySpan)
        case .setWindowSecondarySpan:
            .sizing(.setWindowSecondarySpan)
        case .balanceSizes:
            .dwindle(.balanceSizes)
        }
    }

    var compatibility: LayoutCompatibility {
        switch self {
        case .cycleSizeForward,
             .cycleSizeBackward,
             .balanceSizes:
            .shared
        case .cycleWindowPrimarySpanForward,
             .cycleWindowPrimarySpanBackward,
             .cycleWindowSecondarySpanForward,
             .cycleWindowSecondarySpanBackward,
             .toggleContainerFullPrimarySpan,
             .expandContainerToAvailablePrimarySpan,
             .resetWindowSecondarySpan,
             .setContainerPrimarySpan,
             .setWindowPrimarySpan,
             .setWindowSecondarySpan:
            .niri
        }
    }

    private static func sizeChangeDisplayName(_ change: NiriSizeChange) -> String {
        switch change {
        case let .setFixed(value):
            "Fixed \(Int(value))px"
        case let .setProportion(value):
            "\(Int(value))%"
        case let .adjustFixed(value):
            "\(value >= 0 ? "+" : "")\(Int(value))px"
        case let .adjustProportion(value):
            "\(value >= 0 ? "+" : "")\(Int(value))%"
        }
    }
}
