// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class OverviewViewInteractionTests: XCTestCase {
    private final class Recorder {
        var selected: [WindowHandle] = []
        var closed: [WindowHandle] = []
        var dismissals = 0
        var dragBegins: [(handle: WindowHandle, start: CGPoint)] = []
        var dragUpdates: [CGPoint] = []
        var dragEnds: [CGPoint] = []
    }

    private let cardFrame = CGRect(x: 100, y: 100, width: 200, height: 140)
    private let cardInterior = CGPoint(x: 200, y: 170)

    func testPressAndReleaseActivatesThePressedCardOnMouseUp() throws {
        let surface = try makeSurface()
        defer { surface.panel.close() }

        surface.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: cardInterior, in: surface.panel))
        XCTAssertTrue(surface.recorder.selected.isEmpty)

        surface.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: cardInterior, in: surface.panel))

        XCTAssertEqual(surface.recorder.selected, [surface.item.handle])
        XCTAssertTrue(surface.recorder.dragBegins.isEmpty)
        XCTAssertEqual(surface.recorder.dismissals, 0)
    }

    func testMovingPastThresholdDragsWithoutModifier() throws {
        let surface = try makeSurface()
        defer { surface.panel.close() }
        let moved = CGPoint(x: cardInterior.x + 4, y: cardInterior.y + 8)
        let released = CGPoint(x: 520, y: 400)

        surface.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: cardInterior, in: surface.panel))
        surface.view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: moved, in: surface.panel))
        surface.view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: released, in: surface.panel))
        surface.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: released, in: surface.panel))

        XCTAssertEqual(surface.recorder.dragBegins.count, 1)
        XCTAssertTrue(surface.recorder.dragBegins.first?.handle === surface.item.handle)
        XCTAssertEqual(surface.recorder.dragBegins.first?.start, cardInterior)
        XCTAssertEqual(surface.recorder.dragUpdates, [moved, released])
        XCTAssertEqual(surface.recorder.dragEnds, [released])
        XCTAssertTrue(surface.recorder.selected.isEmpty)
    }

    func testMovingUnderThresholdStillActivates() throws {
        let surface = try makeSurface()
        defer { surface.panel.close() }
        let jitter = CGPoint(x: cardInterior.x + 3, y: cardInterior.y + 2)

        surface.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: cardInterior, in: surface.panel))
        surface.view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: jitter, in: surface.panel))
        surface.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: jitter, in: surface.panel))

        XCTAssertTrue(surface.recorder.dragBegins.isEmpty)
        XCTAssertTrue(surface.recorder.dragUpdates.isEmpty)
        XCTAssertEqual(surface.recorder.selected, [surface.item.handle])
    }

    func testOptionDragStillDrags() throws {
        let surface = try makeSurface()
        defer { surface.panel.close() }
        let moved = CGPoint(x: cardInterior.x + 10, y: cardInterior.y)

        surface.view.mouseDown(with: try mouseEvent(
            .leftMouseDown,
            at: cardInterior,
            modifiers: .option,
            in: surface.panel
        ))
        surface.view.mouseDragged(with: try mouseEvent(
            .leftMouseDragged,
            at: moved,
            modifiers: .option,
            in: surface.panel
        ))
        surface.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: moved, modifiers: .option, in: surface.panel))

        XCTAssertEqual(surface.recorder.dragBegins.count, 1)
        XCTAssertEqual(surface.recorder.dragEnds, [moved])
        XCTAssertTrue(surface.recorder.selected.isEmpty)
    }

    func testCloseButtonClosesOnMouseDownWithoutArmingADrag() throws {
        let surface = try makeSurface()
        defer { surface.panel.close() }
        let size = OverviewRenderStyle.Metrics.closeButtonSize
        let padding = OverviewRenderStyle.Metrics.closeButtonPadding
        let closeButton = CGPoint(x: cardFrame.maxX - padding - size / 2, y: cardFrame.maxY - padding - size / 2)

        surface.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: closeButton, in: surface.panel))
        XCTAssertEqual(surface.recorder.closed, [surface.item.handle])
        surface.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: closeButton, in: surface.panel))

        XCTAssertEqual(surface.recorder.closed, [surface.item.handle])
        XCTAssertTrue(surface.recorder.selected.isEmpty)
        XCTAssertTrue(surface.recorder.dragBegins.isEmpty)
    }

    func testBackdropPressDismissesOnMouseDown() throws {
        let surface = try makeSurface()
        defer { surface.panel.close() }
        let backdrop = CGPoint(x: 700, y: 500)

        surface.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: backdrop, in: surface.panel))
        XCTAssertEqual(surface.recorder.dismissals, 1)
        surface.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: backdrop, in: surface.panel))

        XCTAssertEqual(surface.recorder.dismissals, 1)
        XCTAssertTrue(surface.recorder.selected.isEmpty)
    }

    private struct Surface {
        let view: OverviewView
        let panel: NSPanel
        let item: OverviewWindowItem
        let recorder: Recorder
    }

    private func makeSurface() throws -> Surface {
        let workspaceId = UUID()
        let item = OverviewWindowItem(
            handle: WindowHandle(id: WindowToken(pid: 1, windowId: 1)),
            windowId: 1,
            workspaceId: workspaceId,
            title: "Window",
            appName: "App",
            appIcon: nil,
            originalFrame: CGRect(x: 50, y: 50, width: 600, height: 400),
            overviewFrame: cardFrame,
            matchesSearch: true
        )
        let section = OverviewWorkspaceSection(
            workspaceId: workspaceId,
            name: "Workspace",
            windows: [item],
            sectionFrame: cardFrame,
            labelFrame: .zero,
            gridFrame: cardFrame,
            isActive: true
        )
        var layout = OverviewLayout()
        layout.replaceWorkspaceSections([section])

        let view = OverviewView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let panel = NSPanel(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        let recorder = Recorder()
        view.onWindowSelected = { recorder.selected.append($0) }
        view.onWindowClosed = { recorder.closed.append($0) }
        view.onDismiss = { recorder.dismissals += 1 }
        view.onDragBegin = { recorder.dragBegins.append((handle: $0, start: $1)) }
        view.onDragUpdate = { recorder.dragUpdates.append($0) }
        view.onDragEnd = { recorder.dragEnds.append($0) }
        view.updateLayout(layout, state: .open, searchQuery: "", selectedWindowHandle: nil)
        view.updateLayer()
        return Surface(view: view, panel: panel, item: item, recorder: recorder)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at location: CGPoint,
        modifiers: NSEvent.ModifierFlags = [],
        in window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: modifiers,
            timestamp: 1,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}
