// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import SwiftUI
import XCTest

@MainActor
final class GesturePanelLayoutTests: XCTestCase {
    func testMinimumWidthSupportsAssignmentsAndInlineResolution() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: directory, deferSaves: false),
            autosaveEnabled: false
        )
        settings.gestures.scrollEnabled = true
        settings.gestures.fingerCount = .three
        settings.gestures.workspaceSwipeEnabled = false
        settings.gestures.overviewGestureEnabled = true
        settings.gestures.overviewGestureFingerCount = .four
        settings.gestures.windowMoveEnabled = false
        settings.gestures.windowResizeEnabled = false
        let original = settings.gestures.export()
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let monitor = Monitor(
            id: .init(displayId: 1),
            displayId: 1,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Display"
        )
        let editor = GestureAssignmentEditor()
        try checkLayout(settings: settings, monitor: monitor, editor: editor, name: "gesture-panel")
        editor.submit(.init(action: .move, change: .enabled(true)), settings: settings, monitors: [monitor])
        XCTAssertNotNil(editor.proposal)
        try checkLayout(settings: settings, monitor: monitor, editor: editor, name: "gesture-panel-conflict")
        XCTAssertEqual(settings.gestures.export(), original)
        editor.cancel()
        settings.gestures.workspaceSwipeEnabled = true
        settings.gestures.windowMoveFingerCount = .three
        editor.submit(.init(action: .move, change: .enabled(true)), settings: settings, monitors: [monitor])
        try checkLayout(settings: settings, monitor: monitor, editor: editor, name: "gesture-panel-multiple-conflicts")
    }

    private func checkLayout(
        settings: SettingsStore,
        monitor: Monitor,
        editor: GestureAssignmentEditor,
        name: String
    ) throws {
        let controller = NSHostingController(rootView: Form {
            TrackpadGesturesSettingsPanel(settings: settings, monitors: [monitor], editor: editor)
        }.formStyle(.grouped))
        XCTAssertLessThanOrEqual(controller.sizeThatFits(in: CGSize(width: 499, height: 560)).width, 499)
        let hosting = controller.view
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 499, height: 560),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        if let path = ProcessInfo.processInfo.environment["OMNIWM_GESTURE_PREVIEW_DIR"] {
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name + ".png"))
        }
        withExtendedLifetime(window) {}
    }
}
