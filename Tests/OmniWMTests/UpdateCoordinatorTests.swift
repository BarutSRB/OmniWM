// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation
import Testing

@testable import OmniWM

private func makeTestRelease(
    tagName: String = "v0.5.0",
    name: String = "OmniWM 0.5.0",
    body: String = "Fixes and improvements",
    releasePageURL: URL = URL(string: "https://github.com/BarutSRB/OmniWM/releases/tag/v0.5.0")!,
    publishedAt: Date? = Date(timeIntervalSince1970: 1_700_000_000)
) -> GitHubRelease {
    GitHubRelease(
        tagName: tagName,
        name: name,
        body: body,
        releasePageURL: releasePageURL,
        publishedAt: publishedAt
    )
}

@MainActor
private func waitForUpdateCoordinatorTasks(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    pollIntervalNanoseconds: UInt64 = 10_000_000,
    until condition: (@MainActor @Sendable () -> Bool)? = nil
) async -> Bool {
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutNanoseconds) / 1_000_000_000)
    repeat {
        await Task.yield()
        if condition?() ?? true {
            return true
        }
        try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    } while Date() < deadline

    await Task.yield()
    return condition?() ?? true
}

private struct TestUpdateError: LocalizedError {
    var errorDescription: String? {
        "The update request failed."
    }
}

private final class TestGitHubReleaseService: GitHubReleaseFetching, @unchecked Sendable {
    var results: [Result<GitHubRelease, Error>]
    private(set) var fetchCount = 0

    init(results: [Result<GitHubRelease, Error>]) {
        self.results = results
    }

    func fetchLatestRelease() async throws -> GitHubRelease {
        fetchCount += 1
        guard !results.isEmpty else {
            throw TestUpdateError()
        }
        return try results.removeFirst().get()
    }
}

@MainActor
private final class TestUpdateWindowController: UpdateWindowControlling {
    var onWindowClosedWithoutAction: (() -> Void)?
    private(set) var showCount = 0
    private(set) var lastConfiguration: UpdatePopupConfiguration?
    private(set) var closeCalls: [Bool] = []

    func show(configuration: UpdatePopupConfiguration) {
        showCount += 1
        lastConfiguration = configuration
    }

    func close(markingActionHandled: Bool) {
        closeCalls.append(markingActionHandled)
    }
}

@Suite struct ReleaseVersionTests {
    @Test func normalizesOptionalVPrefixAndComparesNumerically() throws {
        let current = try #require(ReleaseVersion("0.4.4"))
        let next = try #require(ReleaseVersion("v0.4.5"))
        let biggerMinor = try #require(ReleaseVersion("1.10.0"))
        let smallerMinor = try #require(ReleaseVersion("1.2.9"))

        #expect(current < next)
        #expect(biggerMinor > smallerMinor)
        #expect(ReleaseVersion("1.2") == ReleaseVersion("1.2.0"))
    }

    @Test func rejectsInvalidTags() {
        #expect(ReleaseVersion("beta") == nil)
        #expect(ReleaseVersion("v1.2-beta") == nil)
        #expect(ReleaseVersion("") == nil)
    }
}

@Suite(.serialized) @MainActor struct UpdateCoordinatorTests {
    @Test func automaticChecksRunByDefaultAndShowPopupForNewRelease() async {
        resetSharedControllerStateForTests()
        let defaults = makeLayoutPlanTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let runtimeState = runtimeStateStoreForTests(defaults: defaults)
        let service = TestGitHubReleaseService(results: [.success(makeTestRelease())])
        let windowController = TestUpdateWindowController()
        var alerts: [(String, String)] = []
        let coordinator = UpdateCoordinator(
            settings: settings,
            runtimeState: runtimeState,
            releaseService: service,
            currentVersionProvider: { ReleaseVersion("0.4.4") },
            currentVersionStringProvider: { "0.4.4" },
            windowController: windowController,
            infoAlertPresenter: { alerts.append(($0, $1)) }
        )

        coordinator.startAutomaticChecks()
        let didShowUpdate = await waitForUpdateCoordinatorTasks {
            service.fetchCount == 1 && windowController.showCount == 1
        }

        #expect(didShowUpdate)

        #expect(service.fetchCount == 1)
        #expect(windowController.showCount == 1)
        #expect(windowController.lastConfiguration?.latestVersion == "0.5")
        #expect(alerts.isEmpty)
    }

    @Test func automaticChecksRespectDailyThrottle() async {
        resetSharedControllerStateForTests()
        let defaults = makeLayoutPlanTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let runtimeState = runtimeStateStoreForTests(defaults: defaults)
        runtimeState.updaterLastCheckedAt = Date()
        let service = TestGitHubReleaseService(results: [.success(makeTestRelease())])
        let coordinator = UpdateCoordinator(
            settings: settings,
            runtimeState: runtimeState,
            releaseService: service,
            currentVersionProvider: { ReleaseVersion("0.4.4") },
            currentVersionStringProvider: { "0.4.4" },
            windowController: TestUpdateWindowController()
        )

        coordinator.startAutomaticChecks()
        let respectedThrottle = await waitForUpdateCoordinatorTasks {
            service.fetchCount == 0
        }

        #expect(respectedThrottle)

        #expect(service.fetchCount == 0)
    }

    @Test func notNowSuppressesSameReleaseForLaterAutomaticChecks() async {
        resetSharedControllerStateForTests()
        let defaults = makeLayoutPlanTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let runtimeState = runtimeStateStoreForTests(defaults: defaults)
        let firstService = TestGitHubReleaseService(results: [.success(makeTestRelease())])
        let firstWindowController = TestUpdateWindowController()
        let firstCoordinator = UpdateCoordinator(
            settings: settings,
            runtimeState: runtimeState,
            releaseService: firstService,
            currentVersionProvider: { ReleaseVersion("0.4.4") },
            currentVersionStringProvider: { "0.4.4" },
            windowController: firstWindowController
        )

        firstCoordinator.startAutomaticChecks()
        let initialPopupShown = await waitForUpdateCoordinatorTasks {
            firstService.fetchCount == 1 && firstWindowController.lastConfiguration != nil
        }

        #expect(initialPopupShown)
        firstWindowController.lastConfiguration?.notNow()

        let storedSuppression = await waitForUpdateCoordinatorTasks {
            runtimeState.updaterSkippedReleaseTag == "0.5"
        }

        #expect(storedSuppression)
        runtimeState.updaterLastCheckedAt = Date(timeIntervalSinceNow: -90_000)

        let secondService = TestGitHubReleaseService(results: [.success(makeTestRelease())])
        let secondWindowController = TestUpdateWindowController()
        let secondCoordinator = UpdateCoordinator(
            settings: settings,
            runtimeState: runtimeState,
            releaseService: secondService,
            currentVersionProvider: { ReleaseVersion("0.4.4") },
            currentVersionStringProvider: { "0.4.4" },
            windowController: secondWindowController
        )

        secondCoordinator.startAutomaticChecks()
        let secondFetchCompleted = await waitForUpdateCoordinatorTasks {
            secondService.fetchCount == 1
        }

        #expect(secondFetchCompleted)

        #expect(secondService.fetchCount == 1)
        #expect(secondWindowController.showCount == 0)
    }

    @Test func manualChecksBypassThrottleAndDisabledAutomaticSetting() async {
        resetSharedControllerStateForTests()
        let defaults = makeLayoutPlanTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let runtimeState = runtimeStateStoreForTests(defaults: defaults)
        runtimeState.updaterLastCheckedAt = Date()
        settings.updateChecksEnabled = false
        let service = TestGitHubReleaseService(results: [.success(makeTestRelease())])
        let windowController = TestUpdateWindowController()
        let coordinator = UpdateCoordinator(
            settings: settings,
            runtimeState: runtimeState,
            releaseService: service,
            currentVersionProvider: { ReleaseVersion("0.4.4") },
            currentVersionStringProvider: { "0.4.4" },
            windowController: windowController
        )

        coordinator.checkForUpdatesManually()
        let manualPopupShown = await waitForUpdateCoordinatorTasks {
            service.fetchCount == 1 && windowController.showCount == 1
        }

        #expect(manualPopupShown)

        #expect(service.fetchCount == 1)
        #expect(windowController.showCount == 1)
    }

    @Test func manualChecksReportNetworkFailures() async {
        resetSharedControllerStateForTests()
        let defaults = makeLayoutPlanTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        let runtimeState = runtimeStateStoreForTests(defaults: defaults)
        let service = TestGitHubReleaseService(results: [.failure(TestUpdateError())])
        var alerts: [(String, String)] = []
        let coordinator = UpdateCoordinator(
            settings: settings,
            runtimeState: runtimeState,
            releaseService: service,
            currentVersionProvider: { ReleaseVersion("0.4.4") },
            currentVersionStringProvider: { "0.4.4" },
            windowController: TestUpdateWindowController(),
            infoAlertPresenter: { alerts.append(($0, $1)) }
        )

        coordinator.checkForUpdatesManually()
        let manualFailureShown = await waitForUpdateCoordinatorTasks {
            service.fetchCount == 1 && alerts.count == 1
        }

        #expect(manualFailureShown)

        #expect(service.fetchCount == 1)
        #expect(alerts.count == 1)
        #expect(alerts.first?.0 == "Could Not Check for Updates")
    }
}

@Suite(.serialized) @MainActor struct UpdateWindowControllerTests {
    @Test func popupRegistersAsOwnedWindowAndUnregistersOnClose() async {
        resetSharedControllerStateForTests()
        let controller = UpdateWindowController.shared
        controller.show(
            configuration: UpdatePopupConfiguration(
                releaseTitle: "OmniWM 0.5.0",
                currentVersion: "0.4.4",
                latestVersion: "0.5.0",
                publishedDateText: "Jan 1, 2025",
                releaseNotes: "Notes",
                openReleasePage: {},
                copyCommand: {},
                skipThisVersion: {},
                notNow: {}
            )
        )

        guard let window = controller.windowForTests else {
            Issue.record("Expected update window to exist")
            return
        }

        #expect(OwnedWindowRegistry.shared.contains(window: window))

        controller.close(markingActionHandled: true)
        let popupClosed = await waitForUpdateCoordinatorTasks {
            OwnedWindowRegistry.shared.contains(window: window) == false
                && controller.windowForTests == nil
        }

        #expect(popupClosed)

        #expect(OwnedWindowRegistry.shared.contains(window: window) == false)
        #expect(controller.windowForTests == nil)
    }
}
