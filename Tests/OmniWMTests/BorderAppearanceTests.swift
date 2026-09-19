// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class BorderAppearanceTests: XCTestCase {
    func testLegacyDefaultsKeepOptionalEffectsDisabled() {
        let defaults = SettingsExport.defaults().borders

        XCTAssertNil(defaults.gradient)
        XCTAssertNil(defaults.glow)
        XCTAssertNil(defaults.darkColor)
        XCTAssertTrue(defaults.enabled)
        XCTAssertEqual(defaults.width, 5)
    }

    func testAbsentGradientAndGlowProduceSolidConfig() {
        let config = BorderConfig(enabled: true, width: 4, color: solidRed)

        XCTAssertNil(config.gradient)
        XCTAssertNil(config.glow)
    }

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

    func testAbsentGradientAndGlowRemainAbsentInTOML() throws {
        let data = try SettingsTOMLCodec.encode(.defaults())
        let toml = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(toml.contains("[borders.gradient]"))
        XCTAssertFalse(toml.contains("[borders.glow]"))
        let decoded = try SettingsTOMLCodec.decode(data)
        XCTAssertNil(decoded.borders.gradient)
        XCTAssertNil(decoded.borders.glow)
    }

    func testLightAppearanceUsesBaseColor() {
        XCTAssertEqual(BorderConfig.resolvedColor(solidRed, dark: solidBlue, isDark: false), solidRed)
        XCTAssertEqual(BorderConfig.resolvedColor(solidRed, dark: nil, isDark: false), solidRed)
    }

    func testDarkAppearancePrefersDarkColor() {
        XCTAssertEqual(BorderConfig.resolvedColor(solidRed, dark: solidBlue, isDark: true), solidBlue)
    }

    func testDarkAppearanceFallsBackToBaseColorWhenUnset() {
        XCTAssertEqual(BorderConfig.resolvedColor(solidRed, dark: nil, isDark: true), solidRed)
    }

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

    func testDarkBorderColorRoundTripsThroughTOML() throws {
        var export = SettingsExport.defaults()
        export.borders.darkColor = solidBlue

        let data = try SettingsTOMLCodec.encode(export)
        let toml = String(decoding: data, as: UTF8.self)
        let decoded = try SettingsTOMLCodec.decode(data)

        XCTAssertTrue(toml.contains("[borders.darkColor]"))
        XCTAssertEqual(decoded.borders.darkColor, solidBlue)
    }

    func testLegacyTOMLWithoutDarkColorStaysBackwardCompatible() throws {
        let data = try SettingsTOMLCodec.encode(.defaults())
        let toml = String(decoding: data, as: UTF8.self)
        let decoded = try SettingsTOMLCodec.decode(data)

        XCTAssertFalse(toml.contains("darkColor"))
        XCTAssertNil(decoded.borders.darkColor)
    }

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

    func testLegacyGradientTOMLDecodesWithoutDarkColors() throws {
        var export = SettingsExport.defaults()
        export.borders.gradient = BorderGradient.default

        let data = try SettingsTOMLCodec.encode(export)
        let toml = String(decoding: data, as: UTF8.self)
        let decoded = try SettingsTOMLCodec.decode(data)

        XCTAssertFalse(toml.contains("gradient.dark"))
        XCTAssertNil(decoded.borders.gradient?.dark)
    }

    func testEditingDarkGradientStartKeepsEndInheritedThroughTOML() throws {
        let settings = BorderSettings()
        settings.gradient = .default
        settings.setDarkGradientColor(solidBlue, at: \.start)
        settings.gradient?.end = solidRed

        var export = SettingsExport.defaults()
        export.borders = settings.export()
        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export))
        let gradient = try XCTUnwrap(decoded.borders.gradient)
        let resolved = BorderConfig.resolvedGradient(gradient, isDark: true)

        XCTAssertEqual(gradient.dark?.start, solidBlue)
        XCTAssertNil(gradient.dark?.end)
        XCTAssertEqual(resolved.start, solidBlue)
        XCTAssertEqual(resolved.end, solidRed)
    }

    func testEditingDarkGradientEndKeepsStartInheritedThroughTOML() throws {
        let settings = BorderSettings()
        settings.gradient = .default
        settings.setDarkGradientColor(solidRed, at: \.end)
        settings.gradient?.start = solidBlue

        var export = SettingsExport.defaults()
        export.borders = settings.export()
        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export))
        let gradient = try XCTUnwrap(decoded.borders.gradient)
        let resolved = BorderConfig.resolvedGradient(gradient, isDark: true)

        XCTAssertNil(gradient.dark?.start)
        XCTAssertEqual(gradient.dark?.end, solidRed)
        XCTAssertEqual(resolved.start, solidBlue)
        XCTAssertEqual(resolved.end, solidRed)
    }

    func testResettingDarkGradientEndpointsRestoresInheritanceThroughTOML() throws {
        let settings = BorderSettings()
        settings.gradient = .default
        settings.setDarkGradientColor(solidBlue, at: \.start)
        settings.setDarkGradientColor(solidRed, at: \.end)
        settings.setDarkGradientColor(nil, at: \.start)

        XCTAssertNil(settings.gradient?.dark?.start)
        XCTAssertEqual(settings.gradient?.dark?.end, solidRed)

        settings.setDarkGradientColor(nil, at: \.end)
        var export = SettingsExport.defaults()
        export.borders = settings.export()
        let data = try SettingsTOMLCodec.encode(export)
        let decoded = try SettingsTOMLCodec.decode(data)
        let gradient = try XCTUnwrap(decoded.borders.gradient)
        let resolved = BorderConfig.resolvedGradient(gradient, isDark: true)

        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("[borders.gradient.dark]"))
        XCTAssertNil(gradient.dark)
        XCTAssertEqual(resolved.start, gradient.start)
        XCTAssertEqual(resolved.end, gradient.end)
    }

    func testResettingBorderAndGlowColorsRestoresInheritanceThroughTOML() throws {
        let settings = BorderSettings()
        settings.color = solidRed
        settings.darkColor = solidBlue
        settings.glow = BorderGlow(enabled: true, radius: 8, opacity: 0.6, color: solidBlue, darkColor: solidRed)
        settings.glow?.darkColor = nil
        XCTAssertEqual(BorderConfig.resolvedGlow(try XCTUnwrap(settings.glow), isDark: true).color, solidBlue)

        settings.darkColor = nil
        settings.glow?.color = nil
        var export = SettingsExport.defaults()
        export.borders = settings.export()
        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export))
        let glow = try XCTUnwrap(decoded.borders.glow)

        XCTAssertNil(decoded.borders.darkColor)
        XCTAssertEqual(
            BorderConfig.resolvedColor(decoded.borders.color, dark: decoded.borders.darkColor, isDark: true),
            solidRed
        )
        XCTAssertNil(glow.color)
        XCTAssertNil(glow.darkColor)
        XCTAssertNil(BorderConfig.resolvedGlow(glow, isDark: false).color)
        XCTAssertNil(BorderConfig.resolvedGlow(glow, isDark: true).color)
    }

    func testGradientDarkColorsRoundTripAsCodableValues() throws {
        var gradient = BorderGradient.default
        gradient.dark = BorderGradientColors(start: solidBlue, end: solidRed)
        let data = try JSONEncoder().encode(gradient)
        let decoded = try JSONDecoder().decode(BorderGradient.self, from: data)

        XCTAssertEqual(decoded.dark, gradient.dark)
    }

    func testInvalidGlowFallsBackToPreviousValue() {
        let settings = BorderSettings()
        let valid = BorderGlow(enabled: true, radius: 8, opacity: 0.6)
        settings.glow = valid

        var export = SettingsExport.defaults().borders
        export.glow = BorderGlow(enabled: true, radius: 64, opacity: 2)
        settings.apply(export)

        XCTAssertEqual(settings.glow, valid)
    }

    func testInvalidGlowColorFallsBackToPreviousValue() {
        let settings = BorderSettings()
        let valid = BorderGlow(enabled: true, radius: 8, opacity: 0.6, color: solidBlue)
        settings.glow = valid

        var export = SettingsExport.defaults().borders
        export.glow = BorderGlow(
            enabled: true,
            radius: 8,
            opacity: 0.6,
            color: SettingsColor(red: .nan, green: 0, blue: 0, alpha: 1)
        )
        settings.apply(export)

        XCTAssertEqual(settings.glow, valid)
    }

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

    func testNilGradientPassesThroughValidation() {
        let settings = BorderSettings()
        var export = SettingsExport.defaults().borders
        export.gradient = BorderGradient.default
        settings.apply(export)

        export.gradient = nil
        settings.apply(export)

        XCTAssertNil(settings.gradient)
    }

    func testDarkColorClampsComponents() {
        let settings = BorderSettings()
        var export = SettingsExport.defaults().borders
        export.darkColor = SettingsColor(red: -0.5, green: 1.5, blue: 0.5, alpha: 2.0)
        settings.apply(export)

        XCTAssertEqual(settings.darkColor?.red, 0)
        XCTAssertEqual(settings.darkColor?.green, 1)
        XCTAssertEqual(settings.darkColor?.alpha, 1)
    }

    func testInvalidColorFallsBackToPreviousValue() {
        let settings = BorderSettings()
        settings.color = solidRed

        var export = SettingsExport.defaults().borders
        export.color = SettingsColor(red: .nan, green: 0, blue: 0, alpha: 1)
        settings.apply(export)

        XCTAssertEqual(settings.color, solidRed)
    }

    func testInvalidDarkColorFallsBackToPreviousValue() {
        let settings = BorderSettings()
        settings.darkColor = solidBlue

        var export = SettingsExport.defaults().borders
        export.darkColor = SettingsColor(red: .nan, green: 0, blue: 0, alpha: 1)
        settings.apply(export)

        XCTAssertEqual(settings.darkColor, solidBlue)
    }

    func testNilDarkColorClearsPreviousValue() {
        let settings = BorderSettings()
        settings.darkColor = solidBlue

        settings.apply(SettingsExport.defaults().borders)

        XCTAssertNil(settings.darkColor)
    }

    func testResolvedGlowColorsFollowAppearance() {
        let lightOnly = BorderGlow(enabled: true, radius: 8, opacity: 0.6, color: solidBlue)
        XCTAssertEqual(BorderConfig.resolvedGlow(lightOnly, isDark: true).color, solidBlue)
        XCTAssertEqual(BorderConfig.resolvedGlow(lightOnly, isDark: false).color, solidBlue)
        XCTAssertNil(BorderConfig.resolvedGlow(lightOnly, isDark: true).darkColor)

        let both = BorderGlow(enabled: true, radius: 8, opacity: 0.6, color: solidBlue, darkColor: solidRed)
        XCTAssertEqual(BorderConfig.resolvedGlow(both, isDark: true).color, solidRed)
        XCTAssertEqual(BorderConfig.resolvedGlow(both, isDark: false).color, solidBlue)

        let inherited = BorderGlow(enabled: true, radius: 8, opacity: 0.6)
        XCTAssertNil(BorderConfig.resolvedGlow(inherited, isDark: true).color)
        XCTAssertNil(BorderConfig.resolvedGlow(inherited, isDark: false).color)
    }

    func testGlowColorOverridesSurviveTOMLRoundTrip() throws {
        var export = SettingsExport.defaults()
        export.borders.glow = BorderGlow(
            enabled: true,
            radius: 8,
            opacity: 0.6,
            color: solidBlue,
            darkColor: solidRed
        )

        let data = try SettingsTOMLCodec.encode(export)
        let decoded = try SettingsTOMLCodec.decode(data)

        XCTAssertEqual(decoded.borders.glow?.color, solidBlue)
        XCTAssertEqual(decoded.borders.glow?.darkColor, solidRed)
    }

    func testDisabledGlowProducesZeroPadding() {
        let glow = BorderGlow(enabled: false, radius: 16, opacity: 0.5)
        XCTAssertEqual(BorderConfig.renderPadding(glow: glow, scale: 2), 0)
    }

    func testNilGlowProducesZeroPadding() {
        XCTAssertEqual(BorderConfig.renderPadding(glow: nil, scale: 2), 0)
    }

    func testRenderPaddingUsesOnePointFiveMultiplier() {
        let glow = BorderGlow(enabled: true, radius: 8, opacity: 0.6)
        XCTAssertEqual(BorderConfig.renderPadding(glow: glow, scale: 1), 12)
    }

    func testRenderPaddingAtRetinaScale() {
        let glow = BorderGlow(enabled: true, radius: 8, opacity: 0.6)
        XCTAssertEqual(BorderConfig.renderPadding(glow: glow, scale: 2), 12)
    }

    func testRenderPaddingAtMaxRadius() {
        let glow = BorderGlow(enabled: true, radius: 32, opacity: 1)
        XCTAssertEqual(BorderConfig.renderPadding(glow: glow, scale: 1), 48)
    }

    func testRenderPaddingClampsNegativeRadius() {
        let glow = BorderGlow(enabled: true, radius: -5, opacity: 0.6)
        XCTAssertEqual(BorderConfig.renderPadding(glow: glow, scale: 1), 0)
    }

    func testRenderPaddingCapsAtMaxRadius() {
        let glow = BorderGlow(enabled: true, radius: 100, opacity: 0.6)
        XCTAssertEqual(BorderConfig.renderPadding(glow: glow, scale: 1), 48)
    }

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

    func testResolvedGeometryExpandsSurfaceForGlow() {
        let config = BorderConfig(
            enabled: true,
            width: 4,
            color: solidRed,
            glow: BorderGlow(enabled: true, radius: 8, opacity: 0.6)
        )
        let target = CGRect(x: 10, y: 20, width: 100, height: 80)
        let geometry = config.resolvedGeometry(for: target, scale: 1)

        XCTAssertEqual(geometry.surfacePadding, 12)
        XCTAssertEqual(geometry.surfaceFrame, target.insetBy(dx: -16, dy: -16))
        XCTAssertEqual(geometry.targetFrame, target)
    }

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

    func testResolvedGeometryWithoutGlowKeepsLegacyLayout() {
        let config = BorderConfig(enabled: true, width: 4, color: solidRed)
        let target = CGRect(x: 10, y: 20, width: 100, height: 80)
        let geometry = config.resolvedGeometry(for: target, scale: 1).localized()

        XCTAssertEqual(geometry.surfacePadding, 0)
        XCTAssertEqual(geometry.targetFrame, CGRect(x: 4, y: 4, width: 100, height: 80))
        XCTAssertEqual(geometry.surfaceFrame, CGRect(x: 0, y: 0, width: 108, height: 88))
    }

    private let solidRed = SettingsColor(red: 1, green: 0, blue: 0, alpha: 1)
    private let solidBlue = SettingsColor(red: 0, green: 0, blue: 1, alpha: 1)

    private struct CodableBorderAppearance: Codable {
        let gradient: BorderGradient?
        let glow: BorderGlow?
    }
}
