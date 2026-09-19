// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWMCtl
import XCTest

final class CLICompletionCatalogTests: XCTestCase {
    func testScratchpadActionsAndSlotsOccupySeparateArgumentPositions() {
        XCTAssertEqual(CLICompletionCatalog.commandSlotThreeSuggestionsByFirst["scratchpad"], ["assign", "toggle"])
        let slots = (1 ... 10).map(String.init).sorted()
        for action in ["assign", "toggle"] {
            XCTAssertEqual(CLICompletionCatalog.commandSlotFourSuggestionsByPath["scratchpad \(action)"], slots)
        }
    }

    func testFocusCombinesDirectArgumentsAndNestedCommands() {
        XCTAssertEqual(
            CLICompletionCatalog.commandSlotThreeSuggestionsByFirst["focus"],
            ["left", "right", "up", "down", "previous", "down-or-left", "up-or-right"].sorted()
        )
    }

    func testResizePreservesBothLiteralArgumentPositions() {
        XCTAssertEqual(CLICompletionCatalog.commandSlotThreeSuggestionsByFirst["resize"], ["horizontal", "vertical"])
        XCTAssertEqual(CLICompletionCatalog.commandSlotFourFallbackByFirst["resize"], ["grow", "shrink"])
    }
}
