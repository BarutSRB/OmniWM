// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class BorderEffectsTests: XCTestCase {
    private let target = CGRect(x: 16, y: 16, width: 100, height: 80)

    private func makePanel() throws -> BorderLayerPanel {
        guard let panel = BorderLayerPanel(frame: CGRect(x: 0, y: 0, width: 164, height: 144)) else {
            throw XCTSkip("Native rim bridge is unavailable in this environment")
        }
        return panel
    }

    private func geometry(width: CGFloat, padding: CGFloat) -> BorderConfig.ResolvedGeometry {
        let inset = width + padding
        return BorderConfig.ResolvedGeometry(
            targetFrame: CGRect(origin: CGPoint(x: inset, y: inset), size: target.size),
            surfaceFrame: CGRect(
                origin: .zero,
                size: CGSize(width: target.width + 2 * inset, height: target.height + 2 * inset)
            ),
            width: width,
            surfacePadding: padding
        )
    }

    private func updateEffects(
        _ panel: BorderLayerPanel,
        geometry: BorderConfig.ResolvedGeometry,
        gradient: Bool,
        glowOpacity: CGFloat
    ) {
        panel.updateEffects(
            geometry: geometry,
            cornerRadii: WindowCornerRadii(uniform: 9),
            scale: 1,
            baseColor: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            gradientStart: gradient ? CGColor(red: 1, green: 0, blue: 0, alpha: 1) : nil,
            gradientEnd: gradient ? CGColor(red: 0, green: 0, blue: 1, alpha: 1) : nil,
            gradientPoints: gradient ? (start: CGPoint(x: 0, y: 1), end: CGPoint(x: 1, y: 0)) : nil,
            glowOpacity: glowOpacity
        )
    }

    /// Confirms an active gradient replaces the native rim with the ring mask.
    func testGradientHidesRimAndInstallsRingMask() throws {
        let panel = try makePanel()
        updateEffects(panel, geometry: geometry(width: 4, padding: 0), gradient: true, glowOpacity: 0)

        XCTAssertEqual(panel.borderLayer.rimOpacity, 0)
        XCTAssertFalse(panel.gradientStrokeLayer.isHidden)
        XCTAssertNotNil(panel.gradientRingMaskLayer.path)
    }

    /// Confirms the solid path keeps the native rim visible.
    func testSolidKeepsRimVisibleAndHidesGradient() throws {
        let panel = try makePanel()
        updateEffects(panel, geometry: geometry(width: 4, padding: 0), gradient: false, glowOpacity: 0)

        XCTAssertEqual(panel.borderLayer.rimOpacity, 1)
        XCTAssertTrue(panel.gradientStrokeLayer.isHidden)
        XCTAssertNil(panel.gradientRingMaskLayer.path)
    }

    /// Confirms an active glow installs one mask band per physical pixel.
    func testGlowInstallsBandMask() throws {
        let panel = try makePanel()
        updateEffects(panel, geometry: geometry(width: 4, padding: 12), gradient: false, glowOpacity: 0.6)

        XCTAssertFalse(panel.glowColorLayer.isHidden)
        // ceil(12 * 1) bands within the documented 8...48 cap
        XCTAssertEqual(panel.glowMaskLayer.sublayers?.count, 12)
    }

    /// Confirms a disabled glow hides the glow color layer.
    func testNoGlowHidesColorLayer() throws {
        let panel = try makePanel()
        updateEffects(panel, geometry: geometry(width: 4, padding: 0), gradient: false, glowOpacity: 0)

        XCTAssertTrue(panel.glowColorLayer.isHidden)
    }

    /// Confirms the glow band count caps at the documented maximum.
    func testGlowBandCountCapsAtMaximum() throws {
        let panel = try makePanel()
        updateEffects(panel, geometry: geometry(width: 4, padding: 48), gradient: false, glowOpacity: 0.6)

        XCTAssertEqual(panel.glowMaskLayer.sublayers?.count, 48)
    }
}
