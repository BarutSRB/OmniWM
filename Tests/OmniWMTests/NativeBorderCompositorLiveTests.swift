// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreVideo
@testable import OmniWM
import QuartzCore
import ScreenCaptureKit
import XCTest

@MainActor
final class NativeBorderCompositorLiveTests: XCTestCase {
    func testCompositorPreservesIndependentNativeCornersAndTransparentInterior() async throws {
        guard ProcessInfo.processInfo.environment["OMNIWM_RUN_SKYLIGHT_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Live compositor checks require OMNIWM_RUN_SKYLIGHT_LIVE_TESTS=1")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Screen Recording permission is required")
        }
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let target = CGRect(x: screen.frame.midX - 160, y: screen.frame.midY - 120, width: 320, height: 240)
        let config = BorderConfig(
            enabled: true, width: 8, color: SettingsColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let geometry = config.resolvedGeometry(for: target, scale: screen.backingScaleFactor)
        let panel = try XCTUnwrap(BorderLayerPanel(frame: geometry.surfaceFrame))
        defer { panel.close() }
        panel.updateBorder(
            geometry: geometry.localized(),
            cornerRadii: WindowCornerRadii(topLeft: 0, topRight: 16, bottomLeft: 48, bottomRight: 32),
            color: NSColor.red.cgColor, scale: screen.backingScaleFactor
        )
        panel.applyFrame(targetFrame: geometry.targetFrame, surfaceFrame: geometry.surfaceFrame)
        panel.orderBack(nil)
        CATransaction.flush()

        let content = try await SCShareableContent.currentProcess
        let window = try XCTUnwrap(content.windows.first(where: { $0.windowID == CGWindowID(panel.windowNumber) }))
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let capture = SCStreamConfiguration()
        capture.width = Int((geometry.surfaceFrame.width * screen.backingScaleFactor).rounded())
        capture.height = Int((geometry.surfaceFrame.height * screen.backingScaleFactor).rounded())
        capture.pixelFormat = kCVPixelFormatType_32BGRA
        capture.showsCursor = false
        capture.ignoreShadowsSingleWindow = true
        capture.shouldBeOpaque = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: capture)
        let bitmap = try XCTUnwrap(Bitmap(image: image))
        let insets = try XCTUnwrap(bitmap.cornerInsets)

        XCTAssertLessThan(insets[0], insets[1])
        XCTAssertLessThan(insets[1], insets[2])
        XCTAssertLessThan(insets[2], insets[3])
        XCTAssertEqual(bitmap.alpha(x: bitmap.width / 2, y: bitmap.height / 2), 0)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.isMainWindow)
        XCTAssertTrue(panel.ignoresMouseEvents)
    }

    private struct Bitmap {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init?(image: CGImage) {
            width = image.width
            height = image.height
            var storage = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let rendered = storage.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard rendered else { return nil }
            bytes = storage
        }

        func alpha(x: Int, y: Int) -> UInt8 {
            bytes[(y * width + x) * 4 + 3]
        }

        var cornerInsets: [Int]? {
            let topLeft = (0 ..< width / 2).first { isRed(x: $0, y: 1) }
            let topRight = (0 ..< width / 2).first { isRed(x: width - 1 - $0, y: 1) }
            let bottomRight = (0 ..< width / 2).first { isRed(x: width - 1 - $0, y: height - 2) }
            let bottomLeft = (0 ..< width / 2).first { isRed(x: $0, y: height - 2) }
            guard let topLeft, let topRight, let bottomRight, let bottomLeft else { return nil }
            return [topLeft, topRight, bottomRight, bottomLeft]
        }

        private func isRed(x: Int, y: Int) -> Bool {
            let offset = (y * width + x) * 4
            return bytes[offset] > 200 && bytes[offset + 1] < 30 && bytes[offset + 2] < 30
                && bytes[offset + 3] > 200
        }
    }
}
