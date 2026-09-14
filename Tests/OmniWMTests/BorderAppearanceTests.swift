// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class BorderAppearanceTests: XCTestCase {
    // MARK: - Legacy defaults

    /// Confirms legacy settings omit optional border effects by default.
    func testLegacyDefaultsKeepOptionalEffectsDisabled() {
        let defaults = SettingsExport.defaults().borders

        XCTAssertNil(defaults.gradient)
        XCTAssertNil(defaults.glow)
        XCTAssertNil(defaults.darkColor)
        XCTAssertTrue(defaults.enabled)
        XCTAssertEqual(defaults.width, 5)
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
        export.borders.gradient = BorderGradient(
            enabled: true,
            start: solidRed,
            end: solidBlue,
            direction: .topRightToBottomLeft
        )
        export.borders.glow = BorderGlow(enabled: true, radius: 16, opacity: 0.6)

        let data = try SettingsTOMLCodec.encode(export)
        let toml = String(decoding: data, as: UTF8.self)
        let decoded = try SettingsTOMLCodec.decode(data)

        XCTAssertTrue(toml.contains("[borders.gradient]"))
        XCTAssertTrue(toml.contains("[borders.glow]"))
        XCTAssertEqual(decoded.borders.gradient, export.borders.gradient)
        XCTAssertEqual(decoded.borders.glow, export.borders.glow)
    }

    /// Confirms legacy TOML omits absent optional effect tables.
    func testAbsentGradientAndGlowRemainAbsentInTOML() throws {
        let data = try SettingsTOMLCodec.encode(.defaults())
        let toml = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(toml.contains("[borders.gradient]"))
        XCTAssertFalse(toml.contains("[borders.glow]"))
        let decoded = try SettingsTOMLCodec.decode(data)
        XCTAssertNil(decoded.borders.gradient)
        XCTAssertNil(decoded.borders.glow)
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
        export.borders.darkColor = solidBlue

        let data = try SettingsTOMLCodec.encode(export)
        let toml = String(decoding: data, as: UTF8.self)
        let decoded = try SettingsTOMLCodec.decode(data)

        XCTAssertTrue(toml.contains("[borders.darkColor]"))
        XCTAssertEqual(decoded.borders.darkColor, solidBlue)
    }

    /// Confirms legacy TOML without a dark color decodes nil and omits the table.
    func testLegacyTOMLWithoutDarkColorStaysBackwardCompatible() throws {
        let data = try SettingsTOMLCodec.encode(.defaults())
        let toml = String(decoding: data, as: UTF8.self)
        let decoded = try SettingsTOMLCodec.decode(data)

        XCTAssertFalse(toml.contains("darkColor"))
        XCTAssertNil(decoded.borders.darkColor)
    }

    /// Confirms dark gradient colors survive TOML round trips.
    func testGradientDarkColorsRoundTripThroughTOML() throws {
        var export = SettingsExport.defaults()
        var gradient = BorderGradient.default
        gradient.enabled = true
        gradient.dark = BorderGradientColors(start: solidBlue, end: solidRed)
        export.borders.gradient = gradient

        let data = try SettingsTOMLCodec.encode(export)
        let toml = String(decoding: data, as: UTF8.self)
        let decoded = try SettingsTOMLCodec.decode(data)

        XCTAssertTrue(toml.contains("[borders.gradient.dark]"))
        XCTAssertEqual(decoded.borders.gradient?.dark, gradient.dark)
    }

    /// Confirms a dark gradient table with only a start stop decodes and falls
    /// back per stop when resolving dark appearance.
    func testPartialDarkGradientTOMLDecodesWithPerStopFallback() throws {
        var export = SettingsExport.defaults()
        var gradient = BorderGradient.default
        gradient.enabled = true
        gradient.dark = BorderGradientColors(start: solidBlue, end: nil)
        export.borders.gradient = gradient

        let data = try SettingsTOMLCodec.encode(export)
        let toml = String(decoding: data, as: UTF8.self)
        let decoded = try SettingsTOMLCodec.decode(data)

        XCTAssertTrue(toml.contains("[borders.gradient.dark]"))
        XCTAssertFalse(toml.contains("gradient.dark.end"))
        XCTAssertEqual(decoded.borders.gradient?.dark?.start, solidBlue)
        XCTAssertNil(decoded.borders.gradient?.dark?.end)

        let resolved = BorderConfig.resolvedGradient(try XCTUnwrap(decoded.borders.gradient), isDark: true)
        XCTAssertEqual(resolved.start, solidBlue)
        XCTAssertEqual(resolved.end, BorderGradient.default.end)
        XCTAssertNil(resolved.dark)
    }

    /// Confirms legacy gradient TOML without dark colors decodes nil.
    func testLegacyGradientTOMLDecodesWithoutDarkColors() throws {
        var export = SettingsExport.defaults()
        export.borders.gradient = BorderGradient.default

        let data = try SettingsTOMLCodec.encode(export)
        let toml = String(decoding: data, as: UTF8.self)
        let decoded = try SettingsTOMLCodec.decode(data)

        XCTAssertFalse(toml.contains("gradient.dark"))
        XCTAssertNil(decoded.borders.gradient?.dark)
    }

    /// Confirms dark gradient colors survive Codable round trips.
    func testGradientDarkColorsRoundTripAsCodableValues() throws {
        var gradient = BorderGradient.default
        gradient.dark = BorderGradientColors(start: solidBlue, end: solidRed)
        let data = try JSONEncoder().encode(gradient)
        let decoded = try JSONDecoder().decode(BorderGradient.self, from: data)

        XCTAssertEqual(decoded.dark, gradient.dark)
    }

    // MARK: - BorderSettings validation

    /// Confirms invalid glow values keep the prior valid configuration.
    func testInvalidGlowFallsBackToPreviousValue() {
        let settings = BorderSettings()
        let valid = BorderGlow(enabled: true, radius: 8, opacity: 0.6)
        settings.glow = valid

        var export = SettingsExport.defaults().borders
        export.glow = BorderGlow(enabled: true, radius: 64, opacity: 2)
        settings.apply(export)

        XCTAssertEqual(settings.glow, valid)
    }

    /// Confirms non-finite gradient colors keep the prior valid configuration.
    func testInvalidGradientFallsBackToPreviousValue() {
        let settings = BorderSettings()
        let valid = BorderGradient(
            enabled: true,
            start: solidRed,
            end: solidBlue,
            direction: .topLeftToBottomRight
        )
        settings.gradient = valid

        var export = SettingsExport.defaults().borders
        export.gradient = BorderGradient(
            enabled: true,
            start: SettingsColor(red: .infinity, green: 0, blue: 0, alpha: 1),
            end: solidBlue,
            direction: .topLeftToBottomRight
        )
        settings.apply(export)

        XCTAssertEqual(settings.gradient, valid)
    }

    /// Confirms a non-finite dark gradient color keeps the prior configuration.
    func testInvalidDarkGradientColorFallsBack() {
        let settings = BorderSettings()
        let valid = BorderGradient.default
        settings.gradient = valid

        var invalid = valid
        invalid.enabled = true
        invalid.dark = BorderGradientColors(
            start: SettingsColor(red: .infinity, green: 0, blue: 0, alpha: 1),
            end: valid.end
        )
        var export = SettingsExport.defaults().borders
        export.gradient = invalid
        settings.apply(export)

        XCTAssertEqual(settings.gradient, valid)
    }

    /// Confirms finite gradient color components are clamped to unit range.
    func testValidGradientClampsComponentsToUnitRange() {
        let settings = BorderSettings()
        var export = SettingsExport.defaults().borders
        export.gradient = BorderGradient(
            enabled: true,
            start: SettingsColor(red: -0.1, green: 1.5, blue: 0.5, alpha: 2.0),
            end: SettingsColor(red: 0.3, green: 0.4, blue: 0.5, alpha: 0.6),
            direction: .topRightToBottomLeft
        )
        settings.apply(export)

        XCTAssertEqual(settings.gradient?.start.red, 0)
        XCTAssertEqual(settings.gradient?.start.green, 1)
        XCTAssertEqual(settings.gradient?.start.alpha, 1)
    }

    /// Confirms finite dark gradient components are clamped to unit range.
    func testValidGradientClampsDarkComponentsToUnitRange() {
        let settings = BorderSettings()
        var export = SettingsExport.defaults().borders
        export.gradient = BorderGradient(
            enabled: true,
            start: solidRed,
            end: solidBlue,
            direction: .topLeftToBottomRight,
            dark: BorderGradientColors(
                start: SettingsColor(red: -0.1, green: 1.5, blue: 0.5, alpha: 2.0),
                end: SettingsColor(red: 0.3, green: 0.4, blue: 0.5, alpha: 0.6)
            )
        )
        settings.apply(export)

        XCTAssertNotNil(settings.gradient?.dark)
        XCTAssertEqual(settings.gradient?.dark?.start?.red, 0)
        XCTAssertEqual(settings.gradient?.dark?.start?.green, 1)
        XCTAssertEqual(settings.gradient?.dark?.start?.alpha, 1)
    }

    /// Confirms a missing gradient remains absent after validation.
    func testNilGradientPassesThroughValidation() {
        let settings = BorderSettings()
        var export = SettingsExport.defaults().borders
        export.gradient = BorderGradient.default
        settings.apply(export)

        export.gradient = nil
        settings.apply(export)

        XCTAssertNil(settings.gradient)
    }

    /// Confirms the dark border color is clamped during validation.
    func testDarkColorClampsComponents() {
        let settings = BorderSettings()
        var export = SettingsExport.defaults().borders
        export.darkColor = SettingsColor(red: -0.5, green: 1.5, blue: 0.5, alpha: 2.0)
        settings.apply(export)

        XCTAssertEqual(settings.darkColor?.red, 0)
        XCTAssertEqual(settings.darkColor?.green, 1)
        XCTAssertEqual(settings.darkColor?.alpha, 1)
    }

    /// Confirms a non-finite border color keeps the prior valid color.
    func testInvalidColorFallsBackToPreviousValue() {
        let settings = BorderSettings()
        settings.color = solidRed

        var export = SettingsExport.defaults().borders
        export.color = SettingsColor(red: .nan, green: 0, blue: 0, alpha: 1)
        settings.apply(export)

        XCTAssertEqual(settings.color, solidRed)
    }

    /// Confirms a non-finite dark border color keeps the prior dark color.
    func testInvalidDarkColorFallsBackToPreviousValue() {
        let settings = BorderSettings()
        settings.darkColor = solidBlue

        var export = SettingsExport.defaults().borders
        export.darkColor = SettingsColor(red: .nan, green: 0, blue: 0, alpha: 1)
        settings.apply(export)

        XCTAssertEqual(settings.darkColor, solidBlue)
    }

    /// Confirms an absent dark border color still clears the override.
    func testNilDarkColorClearsPreviousValue() {
        let settings = BorderSettings()
        settings.darkColor = solidBlue

        settings.apply(SettingsExport.defaults().borders)

        XCTAssertNil(settings.darkColor)
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
        let withoutGlow = BorderConfig(enabled: true, width: 5, color: solidRed)
        let scale: CGFloat = 2

        XCTAssertEqual(
            BorderConfig.layoutClearance(enabled: withGlow.enabled, width: withGlow.width, scale: scale),
            BorderConfig.layoutClearance(enabled: withoutGlow.enabled, width: withoutGlow.width, scale: scale)
        )
    }

    // MARK: - Resolved geometry

    /// Confirms the overlay surface expands by width plus glow padding.
    func testResolvedGeometryExpandsSurfaceForGlow() {
        let config = BorderConfig(
            enabled: true,
            width: 4,
            color: solidRed,
            glow: BorderGlow(enabled: true, radius: 8, opacity: 0.6)
        )
        let target = CGRect(x: 10, y: 20, width: 100, height: 80)
        let geometry = config.resolvedGeometry(for: target, scale: 1)

        // Surface = target expanded by border width plus glow padding
        XCTAssertEqual(geometry.surfacePadding, 12) // ceil(8 * 1.5)
        XCTAssertEqual(geometry.surfaceFrame, target.insetBy(dx: -16, dy: -16))
        XCTAssertEqual(geometry.targetFrame, target)
    }

    /// Confirms localized geometry offsets the target by width plus padding.
    func testLocalizedGeometryOffsetsByWidthAndPadding() {
        let config = BorderConfig(
            enabled: true,
            width: 4,
            color: solidRed,
            glow: BorderGlow(enabled: true, radius: 8, opacity: 0.6)
        )
        let target = CGRect(x: 10, y: 20, width: 100, height: 80)
        let localized = config.resolvedGeometry(for: target, scale: 1).localized()

        XCTAssertEqual(localized.surfaceFrame, CGRect(x: 0, y: 0, width: 132, height: 112))
        XCTAssertEqual(localized.targetFrame, CGRect(x: 16, y: 16, width: 100, height: 80))
    }

    /// Confirms solid borders keep the legacy zero-padding geometry.
    func testResolvedGeometryWithoutGlowKeepsLegacyLayout() {
        let config = BorderConfig(enabled: true, width: 4, color: solidRed)
        let target = CGRect(x: 10, y: 20, width: 100, height: 80)
        let geometry = config.resolvedGeometry(for: target, scale: 1).localized()

        XCTAssertEqual(geometry.surfacePadding, 0)
        XCTAssertEqual(geometry.targetFrame, CGRect(x: 4, y: 4, width: 100, height: 80))
        XCTAssertEqual(geometry.surfaceFrame, CGRect(x: 0, y: 0, width: 108, height: 88))
    }

    // MARK: - Helpers

    private let solidRed = SettingsColor(red: 1, green: 0, blue: 0, alpha: 1)
    private let solidBlue = SettingsColor(red: 0, green: 0, blue: 1, alpha: 1)

    private struct CodableBorderAppearance: Codable {
        let gradient: BorderGradient?
        let glow: BorderGlow?
    }
}
