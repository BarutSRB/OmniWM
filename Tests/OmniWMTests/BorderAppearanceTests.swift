// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class BorderAppearanceTests: XCTestCase {
    // MARK: - Legacy defaults

    /// Confirms legacy settings omit optional border effects by default.
    func testLegacyDefaultsKeepOptionalEffectsDisabled() {
        let defaults = SettingsExport.defaults()

        XCTAssertNil(defaults.borderGradient)
        XCTAssertNil(defaults.borderGlow)
        XCTAssertNil(defaults.borderColorDark)
        XCTAssertTrue(defaults.bordersEnabled)
        XCTAssertEqual(defaults.borderWidth, 5)
    }

    /// Confirms absent optional effects produce a solid border configuration.
    func testAbsentGradientAndGlowProduceSolidConfig() {
        let config = BorderConfig(enabled: true, width: 4, color: solidRed)

        XCTAssertNil(config.gradient)
        XCTAssertNil(config.glow)
    }

    // MARK: - Codable round-trips

    /// Confirms gradient and glow values survive Codable round trips.
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

    /// Confirms absent optional effects survive Codable round trips.
    func testNilGradientAndGlowRoundTrip() throws {
        let payload = CodableBorderAppearance(gradient: nil, glow: nil)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(CodableBorderAppearance.self, from: data)

        XCTAssertNil(decoded.gradient)
        XCTAssertNil(decoded.glow)
    }

    /// Confirms enabled gradient and glow values survive TOML round trips.
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

    /// Confirms legacy TOML omits absent optional effect tables.
    func testAbsentGradientAndGlowRemainAbsentInTOML() throws {
        let data = try SettingsTOMLCodec.encode(.defaults())
        let toml = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(toml.contains("[borders.gradient]"))
        XCTAssertFalse(toml.contains("[borders.glow]"))
        let decoded = try SettingsTOMLCodec.decode(data)
        XCTAssertNil(decoded.borderGradient)
        XCTAssertNil(decoded.borderGlow)
    }

    /// Confirms every supported gradient direction is Codable.
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

    /// Confirms invalid glow values use the prior valid configuration.
    func testInvalidGlowFallsBackWithoutPartialMutation() {
        let fallback = BorderGlow(enabled: true, radius: 8, opacity: 0.6)
        let invalid = BorderGlow(enabled: true, radius: 64, opacity: 2)

        XCTAssertEqual(SettingsStore.validatedBorderGlow(invalid, fallback: fallback), fallback)
    }

    /// Confirms non-finite gradient colors use the prior valid configuration.
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

    /// Confirms a non-finite glow radius is rejected safely.
    func testNaNGlowRadiusFallsBack() {
        let fallback = BorderGlow(enabled: true, radius: 8, opacity: 0.6)
        let invalid = BorderGlow(enabled: true, radius: .nan, opacity: 0.5)

        XCTAssertEqual(SettingsStore.validatedBorderGlow(invalid, fallback: fallback), fallback)
    }

    /// Confirms a non-finite glow opacity is rejected safely.
    func testNaNGlowOpacityFallsBack() {
        let fallback = BorderGlow(enabled: true, radius: 8, opacity: 0.6)
        let invalid = BorderGlow(enabled: true, radius: 8, opacity: .nan)

        XCTAssertEqual(SettingsStore.validatedBorderGlow(invalid, fallback: fallback), fallback)
    }

    /// Confirms a non-finite gradient endpoint is rejected safely.
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

    /// Confirms finite gradient color components are clamped to unit range.
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

    /// Confirms glow validation accepts documented boundary values.
    func testValidGlowAtBoundaryValues() {
        let zero = BorderGlow(enabled: true, radius: 0, opacity: 0)
        let max = BorderGlow(enabled: true, radius: 32, opacity: 1)

        XCTAssertEqual(SettingsStore.validatedBorderGlow(zero, fallback: nil), zero)
        XCTAssertEqual(SettingsStore.validatedBorderGlow(max, fallback: nil), max)
    }

    /// Confirms a missing gradient remains absent during validation.
    func testNilGradientPassesThroughValidation() {
        XCTAssertNil(SettingsStore.validatedBorderGradient(nil, fallback: .default))
    }

    /// Confirms a missing glow remains absent during validation.
    func testNilGlowPassesThroughValidation() {
        XCTAssertNil(SettingsStore.validatedBorderGlow(nil, fallback: .default))
    }

    // MARK: - Appearance-resolved colors

    /// Confirms light appearance always uses the base color.
    func testLightAppearanceUsesBaseColor() {
        XCTAssertEqual(BorderConfig.resolvedColor(solidRed, dark: solidBlue, isDark: false), solidRed)
        XCTAssertEqual(BorderConfig.resolvedColor(solidRed, dark: nil, isDark: false), solidRed)
    }

    /// Confirms dark appearance prefers the dark override color.
    func testDarkAppearancePrefersDarkColor() {
        XCTAssertEqual(BorderConfig.resolvedColor(solidRed, dark: solidBlue, isDark: true), solidBlue)
    }

    /// Confirms dark appearance falls back to the base color when unset.
    func testDarkAppearanceFallsBackToBaseColorWhenUnset() {
        XCTAssertEqual(BorderConfig.resolvedColor(solidRed, dark: nil, isDark: true), solidRed)
    }

    /// Confirms gradient resolution resolves both stops and drops the override.
    func testResolvedGradientResolvesStopsAndDropsDarkOverride() {
        let gradient = BorderGradient(
            enabled: true,
            start: solidRed,
            end: solidBlue,
            direction: .topRightToBottomLeft,
            dark: BorderGradientColors(
                start: SettingsColor(red: 1, green: 1, blue: 0, alpha: 1),
                end: SettingsColor(red: 0, green: 1, blue: 1, alpha: 1)
            )
        )

        let darkResolved = BorderConfig.resolvedGradient(gradient, isDark: true)
        XCTAssertEqual(darkResolved.start, gradient.dark?.start)
        XCTAssertEqual(darkResolved.end, gradient.dark?.end)
        XCTAssertNil(darkResolved.dark)

        let lightResolved = BorderConfig.resolvedGradient(gradient, isDark: false)
        XCTAssertEqual(lightResolved.start, solidRed)
        XCTAssertEqual(lightResolved.end, solidBlue)
        XCTAssertNil(lightResolved.dark)
    }

    /// Confirms gradient resolution falls back per stop when dark stops differ.
    func testResolvedGradientFallsBackPerStop() {
        let gradient = BorderGradient(
            enabled: true,
            start: solidRed,
            end: solidBlue,
            direction: .topLeftToBottomRight,
            dark: BorderGradientColors(start: solidBlue, end: solidBlue)
        )

        XCTAssertEqual(BorderConfig.resolvedGradient(gradient, isDark: true).start, solidBlue)
    }

    // MARK: - Dark appearance settings round-trips

    /// Confirms the dark border color survives TOML round trips.
    func testDarkBorderColorRoundTripsThroughTOML() throws {
        var export = SettingsExport.defaults()
        export.borderColorDark = solidBlue

        let data = try SettingsTOMLCodec.encode(export)
        let toml = String(decoding: data, as: UTF8.self)
        let decoded = try SettingsTOMLCodec.decode(data)

        XCTAssertTrue(toml.contains("[borders.darkColor]"))
        XCTAssertEqual(decoded.borderColorDark, solidBlue)
    }

    /// Confirms legacy TOML without a dark color decodes nil and omits the table.
    func testLegacyTOMLWithoutDarkColorStaysBackwardCompatible() throws {
        let data = try SettingsTOMLCodec.encode(.defaults())
        let toml = String(decoding: data, as: UTF8.self)
        let decoded = try SettingsTOMLCodec.decode(data)

        XCTAssertFalse(toml.contains("darkColor"))
        XCTAssertNil(decoded.borderColorDark)
    }

    /// Confirms dark gradient colors survive TOML round trips.
    func testGradientDarkColorsRoundTripThroughTOML() throws {
        var export = SettingsExport.defaults()
        var gradient = BorderGradient.default
        gradient.enabled = true
        gradient.dark = BorderGradientColors(start: solidBlue, end: solidRed)
        export.borderGradient = gradient

        let data = try SettingsTOMLCodec.encode(export)
        let toml = String(decoding: data, as: UTF8.self)
        let decoded = try SettingsTOMLCodec.decode(data)

        XCTAssertTrue(toml.contains("[borders.gradient.dark]"))
        XCTAssertEqual(decoded.borderGradient?.dark, gradient.dark)
    }

    /// Confirms legacy gradient TOML without dark colors decodes nil.
    func testLegacyGradientTOMLDecodesWithoutDarkColors() throws {
        var export = SettingsExport.defaults()
        export.borderGradient = BorderGradient.default

        let data = try SettingsTOMLCodec.encode(export)
        let toml = String(decoding: data, as: UTF8.self)
        let decoded = try SettingsTOMLCodec.decode(data)

        XCTAssertFalse(toml.contains("gradient.dark"))
        XCTAssertNil(decoded.borderGradient?.dark)
    }

    /// Confirms dark gradient colors survive Codable round trips.
    func testGradientDarkColorsRoundTripAsCodableValues() throws {
        var gradient = BorderGradient.default
        gradient.dark = BorderGradientColors(start: solidBlue, end: solidRed)
        let data = try JSONEncoder().encode(gradient)
        let decoded = try JSONDecoder().decode(BorderGradient.self, from: data)

        XCTAssertEqual(decoded.dark, gradient.dark)
    }

    /// Confirms a non-finite dark gradient color uses the prior valid configuration.
    func testInvalidDarkGradientColorFallsBack() {
        let fallback = BorderGradient.default
        var invalid = fallback
        invalid.enabled = true
        invalid.dark = BorderGradientColors(
            start: SettingsColor(red: .infinity, green: 0, blue: 0, alpha: 1),
            end: fallback.end
        )

        XCTAssertEqual(SettingsStore.validatedBorderGradient(invalid, fallback: fallback), fallback)
    }

    /// Confirms finite dark gradient components are clamped to unit range.
    func testValidGradientClampsDarkComponentsToUnitRange() {
        var wide = BorderGradient.default
        wide.enabled = true
        wide.dark = BorderGradientColors(
            start: SettingsColor(red: -0.1, green: 1.5, blue: 0.5, alpha: 2.0),
            end: SettingsColor(red: 0.3, green: 0.4, blue: 0.5, alpha: 0.6)
        )
        let result = SettingsStore.validatedBorderGradient(wide, fallback: nil)

        XCTAssertNotNil(result?.dark)
        XCTAssertEqual(result?.dark?.start.red, 0)
        XCTAssertEqual(result?.dark?.start.green, 1)
        XCTAssertEqual(result?.dark?.start.alpha, 1)
    }

    // MARK: - Render padding

    /// Confirms disabled glow does not expand the overlay surface.
    func testDisabledGlowProducesZeroPadding() {
        let glow = BorderGlow(enabled: false, radius: 16, opacity: 0.5)
        XCTAssertEqual(BorderConfig.renderPadding(glow: glow, scale: 2), 0)
    }

    /// Confirms absent glow does not expand the overlay surface.
    func testNilGlowProducesZeroPadding() {
        XCTAssertEqual(BorderConfig.renderPadding(glow: nil, scale: 2), 0)
    }

    /// Confirms zero-radius glow does not expand the overlay surface.
    func testZeroRadiusGlowProducesZeroPadding() {
        let glow = BorderGlow(enabled: true, radius: 0, opacity: 0.6)
        XCTAssertEqual(BorderConfig.renderPadding(glow: glow, scale: 1), 0)
    }

    /// Confirms render padding uses the documented falloff multiplier.
    func testRenderPaddingUsesOnePointFiveMultiplier() {
        let glow = BorderGlow(enabled: true, radius: 8, opacity: 0.6)
        // ceil(8 * 1.5 * 1) / 1 = 12
        XCTAssertEqual(BorderConfig.renderPadding(glow: glow, scale: 1), 12)
    }

    /// Confirms render padding remains physical-pixel aligned at 2x scale.
    func testRenderPaddingAtRetinaScale() {
        let glow = BorderGlow(enabled: true, radius: 8, opacity: 0.6)
        // ceil(8 * 1.5 * 2) / 2 = ceil(24) / 2 = 12
        XCTAssertEqual(BorderConfig.renderPadding(glow: glow, scale: 2), 12)
    }

    /// Confirms maximum supported radius produces bounded padding.
    func testRenderPaddingAtMaxRadius() {
        let glow = BorderGlow(enabled: true, radius: 32, opacity: 1)
        // ceil(32 * 1.5 * 1) / 1 = 48
        XCTAssertEqual(BorderConfig.renderPadding(glow: glow, scale: 1), 48)
    }

    /// Confirms negative radius cannot create overlay padding.
    func testRenderPaddingClampsNegativeRadius() {
        let glow = BorderGlow(enabled: true, radius: -5, opacity: 0.6)
        XCTAssertEqual(BorderConfig.renderPadding(glow: glow, scale: 1), 0)
    }

    /// Confirms oversized radius is capped at the supported maximum.
    func testRenderPaddingCapsAtMaxRadius() {
        let glow = BorderGlow(enabled: true, radius: 100, opacity: 0.6)
        // Clamped to 32, then ceil(32 * 1.5) = 48
        XCTAssertEqual(BorderConfig.renderPadding(glow: glow, scale: 1), 48)
    }

    // MARK: - Layout clearance unaffected by glow

    /// Confirms glow does not alter width-based layout clearance.
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

    /// Confirms ring geometry excludes the outward glow padding.
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

    /// Confirms solid borders retain zero glow padding.
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
