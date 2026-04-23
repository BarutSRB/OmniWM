// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing

@testable import OmniWM

@Suite struct AppBootstrapPlannerTests {
    @Test func bootstrapBlocksWhenDisplaysHaveSeparateSpacesIsEnabled() {
        let spacesDefaults = UserDefaults(suiteName: "com.omniwm.bootstrap.test.\(UUID().uuidString)")!
        spacesDefaults.set(false, forKey: DisplaysHaveSeparateSpacesRequirement.spansDisplaysKey)

        let decision = AppBootstrapPlanner.decision(
            spacesRequirement: DisplaysHaveSeparateSpacesRequirement {
                spacesDefaults
            }
        )

        #expect(decision == .requireDisplaysHaveSeparateSpacesDisabled)
    }

    @Test func bootstrapBlocksWhenSpacesPreferenceIsMissing() {
        let spacesDefaults = UserDefaults(suiteName: "com.omniwm.bootstrap.test.\(UUID().uuidString)")!

        let decision = AppBootstrapPlanner.decision(
            spacesRequirement: DisplaysHaveSeparateSpacesRequirement {
                spacesDefaults
            }
        )

        #expect(decision == .requireDisplaysHaveSeparateSpacesDisabled)
    }

    @Test func bootstrapContinuesWhenDisplaysSpanAllScreens() {
        let spacesDefaults = UserDefaults(suiteName: "com.omniwm.bootstrap.test.\(UUID().uuidString)")!
        spacesDefaults.set(true, forKey: DisplaysHaveSeparateSpacesRequirement.spansDisplaysKey)

        let decision = AppBootstrapPlanner.decision(
            spacesRequirement: DisplaysHaveSeparateSpacesRequirement {
                spacesDefaults
            }
        )

        #expect(decision == .boot)
    }
}
