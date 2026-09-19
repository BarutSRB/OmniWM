// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Combine
@testable import OmniWM
import XCTest

@MainActor
final class CommandPaletteFocusTests: XCTestCase {
    func testOpeningAndReopeningFocusSearchWithoutClicking() async throws {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        let panel = try await showAndWaitForEditing(fixture)

        try fixture.insertText("first")
        XCTAssertEqual(fixture.palette.searchText, "first")

        fixture.palette.toggle(wmController: fixture.controller)
        fixture.layout()
        XCTAssertFalse(fixture.palette.isVisible)
        XCTAssertFalse(panel.isVisible)

        let reopenedPanel = try await showAndWaitForEditing(fixture)
        XCTAssertTrue(reopenedPanel === panel)
        XCTAssertEqual(fixture.palette.searchText, "")
        try fixture.insertText("second")
        XCTAssertEqual(fixture.palette.searchText, "second")
    }

    func testChangingModeReturnsFocusToSearch() async throws {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        let panel = try await showAndWaitForEditing(fixture)
        XCTAssertTrue(panel.makeFirstResponder(nil))

        fixture.palette.selectedMode = .clipboard
        fixture.layout()

        try fixture.insertText("clipboard")
        XCTAssertEqual(fixture.palette.searchText, "clipboard")
        XCTAssertEqual(fixture.palette.selectedMode, .clipboard)

        XCTAssertTrue(panel.makeFirstResponder(nil))
        fixture.palette.selectedMode = .windows
        fixture.layout()

        try fixture.insertText("window")
        XCTAssertTrue(fixture.palette.searchText.contains("window"))
        XCTAssertEqual(fixture.palette.selectedMode, .windows)
    }

    func testArrowKeysNavigateBeforeAnyMouseInteraction() async throws {
        let fixture = CommandPaletteFocusFixture(initialMode: .clipboard)
        defer { fixture.cleanup() }
        let panel = try await showAndWaitForEditing(fixture)
        let first = try XCTUnwrap(fixture.palette.filteredClipboardItems.first)
        let last = try XCTUnwrap(fixture.palette.filteredClipboardItems.last)
        XCTAssertEqual(fixture.palette.selectedItemID, .clipboard(first.id))

        try sendKey(keyCode: 125, characters: "\u{F701}", to: panel)
        XCTAssertEqual(fixture.palette.selectedItemID, .clipboard(last.id))
        try sendKey(keyCode: 126, characters: "\u{F700}", to: panel)
        XCTAssertEqual(fixture.palette.selectedItemID, .clipboard(first.id))

        try fixture.insertText("typed")
        XCTAssertEqual(fixture.palette.searchText, "typed")
    }

    private func showAndWaitForEditing(_ fixture: CommandPaletteFocusFixture) async throws -> NSPanel {
        let panel = try fixture.show()
        let editing = expectation(description: "Search becomes the first responder")
        let observation = panel.publisher(for: \.firstResponder, options: [.initial, .new])
            .first { $0 is NSTextView }
            .sink { _ in editing.fulfill() }
        await fulfillment(of: [editing], timeout: 1)
        observation.cancel()
        return panel
    }

    private func sendKey(keyCode: UInt16, characters: String, to panel: NSPanel) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
        NSApp.sendEvent(event)
    }
}

@MainActor
private final class CommandPaletteFocusFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("OmniWMPaletteFocusTests-\(UUID())")
    let controller: WMController
    let palette: CommandPaletteController
    let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
    private(set) var panel: NSPanel?

    init(initialMode: CommandPaletteMode = .windows) {
        _ = NSApplication.shared
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config"),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: root.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        settings.commandPaletteLastMode = initialMode
        controller = WMController(
            settings: settings,
            clipboardHistoryDirectory: root.appendingPathComponent("clipboard"),
            diagnosticsDirectory: root.appendingPathComponent("diagnostics"),
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        var environment = CommandPaletteEnvironment()
        environment.frontmostApplication = { nil }
        environment.runningApplication = { _ in nil }
        environment.activateOmniWM = {}
        environment.isClipboardHistoryEnabled = { _ in true }
        environment.clipboardItems = { _ in
            ["Alpha", "Beta"].map { title in
                ClipboardPaletteItem(
                    id: UUID(),
                    title: title,
                    subtitle: "",
                    kind: .text,
                    sourceBundleIdentifier: nil,
                    lastCopiedAt: Date(timeIntervalSince1970: 0),
                    numberOfCopies: 1,
                    byteCount: title.utf8.count
                )
            }
        }
        palette = CommandPaletteController(
            motionPolicy: MotionPolicy(animationsEnabled: false),
            environment: environment,
            ownedWindowRegistry: registry
        )
    }

    func show() throws -> NSPanel {
        palette.show(wmController: controller)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.delegate === palette } as? NSPanel)
        panel.isReleasedWhenClosed = false
        self.panel = panel
        layout()
        return panel
    }

    func layout() {
        panel?.contentView?.needsLayout = true
        panel?.contentView?.layoutSubtreeIfNeeded()
        panel?.displayIfNeeded()
    }

    func insertText(_ text: String) throws {
        let panel = try XCTUnwrap(panel)
        let editor = try XCTUnwrap(
            panel.firstResponder as? NSTextView,
            "visible=\(palette.isVisible) key=\(panel.isKeyWindow) responder=\(String(describing: panel.firstResponder))"
        )
        XCTAssertTrue(editor.isFieldEditor)
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func cleanup() {
        if palette.isVisible {
            palette.toggle(wmController: controller)
        }
        if let panel {
            registry.unregister(panel)
            panel.close()
            panel.contentView = nil
            panel.delegate = nil
        }
        try? FileManager.default.removeItem(at: root)
    }
}
