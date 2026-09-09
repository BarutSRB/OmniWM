// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class BorderAppearanceTests: XCTestCase {
    // MARK: - Legacy defaults

    func testLegacyDefaultsKeepOptionalEffectsDisabled() {
        let defaults = SettingsExport.defaults()

        XCTAssertNil(defaults.borderGradient)
        XCTAssertNil(defaults.borderGlow)
        XCTAssertTrue(defaults.bordersEnabled)
        XCTAssertEqual(defaults.borderWidth, 5)
    }

    func testAbsentGradientAndGlowProduceSolidConfig() {
        let config = BorderConfig(enabled: true, width: 4, color: solidRed)

        XCTAssertNil(config.gradient)
        XCTAssertNil(config.glow)
    }

    // MARK: - Codable round-trips

    func testGradientAndGlowRoundTripAsCodableValues() throws {
        let gradient = BorderGradient(
            enabled: true,
            start: SettingsColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4),
            end: SettingsColor(red: 0.7, green: 0.8, blue: 0.9, alpha: 1),
            direction: .topRightToBottomLeft
        )
        let glow = BorderGlow(enabled: true, radius: 8, opacity: 0.6)
        let payload = CodableBorderAppearance(gradient: gradient, glow: glow)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(CodableBorderAppearance.self, from: data)

        XCTAssertEqual(decoded.gradient, gradient)
        XCTAssertEqual(decoded.glow, glow)
    }

    func testNilGradientAndGlowRoundTrip() throws {
        let payload = CodableBorderAppearance(gradient: nil, glow: nil)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(CodableBorderAppearance.self, from: data)

        XCTAssertNil(decoded.gradient)
        XCTAssertNil(decoded.glow)
    }

    func testGradientAndGlowRoundTripThroughTOML() throws {
        var export = SettingsExport.defaults()
        export.borderGradient = BorderGradient(
            enabled: true,
            start: solidRed,
            end: solidBlue,
            direction: .topRightToBottomLeft
        )
        export.borderGlow = BorderGlow(enabled: true, radius: 16, opacity: 0.6)

        let data = try SettingsTOMLCodec.encode(export)
        let toml = String(decoding: data, as: UTF8.self)
        let decoded = try SettingsTOMLCodec.decode(data)

        XCTAssertTrue(toml.contains("[borders.gradient]"))
        XCTAssertTrue(toml.contains("[borders.glow]"))
        XCTAssertEqual(decoded.borderGradient, export.borderGradient)
        XCTAssertEqual(decoded.borderGlow, export.borderGlow)
    }

    func testAbsentGradientAndGlowRemainAbsentInTOML() throws {
        let data = try SettingsTOMLCodec.encode(.defaults())
        let toml = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(toml.contains("[borders.gradient]"))
        XCTAssertFalse(toml.contains("[borders.glow]"))
        let decoded = try SettingsTOMLCodec.decode(data)
        XCTAssertNil(decoded.borderGradient)
        XCTAssertNil(decoded.borderGlow)
    }

    func testGradientDirectionRoundTrip() throws {
        for direction in BorderGradientDirection.allCases {
            let gradient = BorderGradient(
                enabled: true,
                start: solidRed,
                end: solidBlue,
                direction: direction
            )
            let data = try JSONEncoder().encode(gradient)
            let decoded = try JSONDecoder().decode(BorderGradient.self, from: data)
            XCTAssertEqual(decoded.direction, direction)
        }
    }

    // MARK: - Validation

    func testInvalidGlowFallsBackWithoutPartialMutation() {
        let fallback = BorderGlow(enabled: true, radius: 8, opacity: 0.6)
        let invalid = BorderGlow(enabled: true, radius: 64, opacity: 2)

        XCTAssertEqual(SettingsStore.validatedBorderGlow(invalid, fallback: fallback), fallback)
    }

    func testInvalidGradientFallsBackWithoutPartialMutation() {
        let fallback = BorderGradient.default
        let invalid = BorderGradient(
            enabled: true,
            start: SettingsColor(red: .infinity, green: 0, blue: 0, alpha: 1),
            end: fallback.end,
            direction: fallback.direction
        )

        XCTAssertEqual(SettingsStore.validatedBorderGradient(invalid, fallback: fallback), fallback)
    }

    func testNaNGlowRadiusFallsBack() {
        let fallback = BorderGlow(enabled: true, radius: 8, opacity: 0.6)
        let invalid = BorderGlow(enabled: true, radius: .nan, opacity: 0.5)

        XCTAssertEqual(SettingsStore.validatedBorderGlow(invalid, fallback: fallback), fallback)
    }

    func testNaNGlowOpacityFallsBack() {
        let fallback = BorderGlow(enabled: true, radius: 8, opacity: 0.6)
        let invalid = BorderGlow(enabled: true, radius: 8, opacity: .nan)

        XCTAssertEqual(SettingsStore.validatedBorderGlow(invalid, fallback: fallback), fallback)
    }

    func testNaNGradientEndColorFallsBack() {
        let fallback = BorderGradient.default
        let invalid = BorderGradient(
            enabled: true,
            start: solidRed,
            end: SettingsColor(red: 0, green: .nan, blue: 0, alpha: 1),
            direction: .topLeftToBottomRight
        )

        XCTAssertEqual(SettingsStore.validatedBorderGradient(invalid, fallback: fallback), fallback)
    }

    func testValidGradientClampsComponentsToUnitRange() {
        let wide = BorderGradient(
            enabled: true,
            start: SettingsColor(red: -0.1, green: 1.5, blue: 0.5, alpha: 2.0),
            end: SettingsColor(red: 0.3, green: 0.4, blue: 0.5, alpha: 0.6),
            direction: .topRightToBottomLeft
        )
        let result = SettingsStore.validatedBorderGradient(wide, fallback: nil)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.start.red, 0)
        XCTAssertEqual(result?.start.green, 1)
        XCTAssertEqual(result?.start.alpha, 1)
    }

    func testValidGlowAtBoundaryValues() {
        let zero = BorderGlow(enabled: true, radius: 0, opacity: 0)
        let max = BorderGlow(enabled: true, radius: 32, opacity: 1)

        XCTAssertEqual(SettingsStore.validatedBorderGlow(zero, fallback: nil), zero)
        XCTAssertEqual(SettingsStore.validatedBorderGlow(max, fallback: nil), max)
    }

    func testNilGradientPassesThroughValidation() {
        XCTAssertNil(SettingsStore.validatedBorderGradient(nil, fallback: .default))
    }

    func testNilGlowPassesThroughValidation() {
        XCTAssertNil(SettingsStore.validatedBorderGlow(nil, fallback: .default))
    }

    // MARK: - Render padding

    func testDisabledGlowProducesZeroPadding() {
        let glow = BorderGlow(enabled: false, radius: 16, opacity: 0.5)
        XCTAssertEqual(BorderConfig.renderPadding(glow: glow, scale: 2), 0)
    }

    func testNilGlowProducesZeroPadding() {
        XCTAssertEqual(BorderConfig.renderPadding(glow: nil, scale: 2), 0)
    }

    func testZeroRadiusGlowProducesZeroPadding() {
        let glow = BorderGlow(enabled: true, radius: 0, opacity: 0.6)
        XCTAssertEqual(BorderConfig.renderPadding(glow: glow, scale: 1), 0)
    }

    func testRenderPaddingUsesOnePointFiveMultiplier() {
        let glow = BorderGlow(enabled: true, radius: 8, opacity: 0.6)
        // ceil(8 * 1.5 * 1) / 1 = 12
        XCTAssertEqual(BorderConfig.renderPadding(glow: glow, scale: 1), 12)
    }

    func testRenderPaddingAtRetinaScale() {
        let glow = BorderGlow(enabled: true, radius: 8, opacity: 0.6)
        // ceil(8 * 1.5 * 2) / 2 = ceil(24) / 2 = 12
        XCTAssertEqual(BorderConfig.renderPadding(glow: glow, scale: 2), 12)
    }

    func testRenderPaddingAtMaxRadius() {
        let glow = BorderGlow(enabled: true, radius: 32, opacity: 1)
        // ceil(32 * 1.5 * 1) / 1 = 48
        XCTAssertEqual(BorderConfig.renderPadding(glow: glow, scale: 1), 48)
    }

    func testRenderPaddingClampsNegativeRadius() {
        let glow = BorderGlow(enabled: true, radius: -5, opacity: 0.6)
        XCTAssertEqual(BorderConfig.renderPadding(glow: glow, scale: 1), 0)
    }

    func testRenderPaddingCapsAtMaxRadius() {
        let glow = BorderGlow(enabled: true, radius: 100, opacity: 0.6)
        // Clamped to 32, then ceil(32 * 1.5) = 48
        XCTAssertEqual(BorderConfig.renderPadding(glow: glow, scale: 1), 48)
    }

    // MARK: - Layout clearance unaffected by glow

    func testLayoutClearanceIgnoresGlow() {
        let withGlow = BorderConfig(
            enabled: true,
            width: 5,
            color: solidRed,
            glow: BorderGlow(enabled: true, radius: 16, opacity: 0.8)
        )
        let withoutGlow = BorderConfig(
            enabled: true,
            width: 5,
            color: solidRed
        )
        let scale: CGFloat = 2

        XCTAssertEqual(
            BorderConfig.layoutClearance(enabled: withGlow.enabled, width: withGlow.width, scale: scale),
            BorderConfig.layoutClearance(enabled: withoutGlow.enabled, width: withoutGlow.width, scale: scale)
        )
    }

    // MARK: - Resolved geometry

    func testResolvedGeometryRingFrameExcludesGlowPadding() {
        let config = BorderConfig(
            enabled: true,
            width: 4,
            color: solidRed,
            glow: BorderGlow(enabled: true, radius: 8, opacity: 0.6)
        )
        let target = CGRect(x: 10, y: 20, width: 100, height: 80)
        let geometry = config.resolvedGeometry(for: target, scale: 1)

        // Ring = target expanded by border width only
        XCTAssertEqual(geometry.ringFrame, target.insetBy(dx: -4, dy: -4))
        // Surface = ring expanded by glow padding
        XCTAssertEqual(geometry.surfacePadding, 12) // ceil(8 * 1.5)
        XCTAssertEqual(
            geometry.surfaceFrame,
            geometry.ringFrame.insetBy(dx: -12, dy: -12)
        )
    }

    func testResolvedGeometryWithoutGlowHasZeroPadding() {
        let config = BorderConfig(enabled: true, width: 4, color: solidRed)
        let target = CGRect(x: 10, y: 20, width: 100, height: 80)
        let geometry = config.resolvedGeometry(for: target, scale: 1)

        XCTAssertEqual(geometry.surfacePadding, 0)
        XCTAssertEqual(geometry.ringFrame, geometry.surfaceFrame)
    }

    // MARK: - Helpers

    private let solidRed = SettingsColor(red: 1, green: 0, blue: 0, alpha: 1)
    private let solidBlue = SettingsColor(red: 0, green: 0, blue: 1, alpha: 1)

    private struct CodableBorderAppearance: Codable {
        let gradient: BorderGradient?
        let glow: BorderGlow?
    }
}
