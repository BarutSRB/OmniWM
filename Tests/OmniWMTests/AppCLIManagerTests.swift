// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing

@testable import OmniWM

private func makeAppCLIManagerTestDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("omniwm-cli-manager-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeBundledCLIAppBundle(in root: URL) throws -> URL {
    let appURL = root.appendingPathComponent("OmniWM.app", isDirectory: true)
    let macOSDirectory = appURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOSDirectory, withIntermediateDirectories: true)

    let cliURL = macOSDirectory.appendingPathComponent("omniwmctl", isDirectory: false)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: cliURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliURL.path)
    return appURL
}

private func makeCLIManager(
    homeDirectory: URL,
    bundleURL: URL,
    pathDirectories: [URL],
    homebrewLinkURLs: [URL] = []
) -> AppCLIManager {
    AppCLIManager(
        fileManager: .default,
        environmentProvider: {
            ["PATH": pathDirectories.map(\.path).joined(separator: ":")]
        },
        bundleURLProvider: { bundleURL },
        homeDirectoryURLProvider: { homeDirectory },
        homebrewLinkURLsProvider: { homebrewLinkURLs }
    )
}

@Suite(.serialized) struct AppCLIManagerTests {
    @Test func installCLIUsesFirstWritablePathDirectoryInsideHome() throws {
        let root = makeAppCLIManagerTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        let userBin = homeDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: userBin, withIntermediateDirectories: true)
        let appBundleURL = try makeBundledCLIAppBundle(in: root)
        let manager = makeCLIManager(
            homeDirectory: homeDirectory,
            bundleURL: appBundleURL,
            pathDirectories: [userBin]
        )

        let result = try manager.installCLIToPATH()
        let expectedLinkURL = userBin.appendingPathComponent("omniwmctl", isDirectory: false)

        #expect(result == .installed(linkURL: expectedLinkURL, directoryOnPath: true))
        #expect(FileManager.default.fileExists(atPath: expectedLinkURL.path))
        #expect(manager.exposureStatus() == .appManaged(linkURL: expectedLinkURL, directoryOnPath: true))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: expectedLinkURL.path) == manager.bundledCLIURL.path)
    }

    @Test func installCLIFallsBackToLocalBinWhenNoUserPathDirectoryExists() throws {
        let root = makeAppCLIManagerTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        let outsidePathDirectory = root.appendingPathComponent("outside/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: outsidePathDirectory, withIntermediateDirectories: true)
        let appBundleURL = try makeBundledCLIAppBundle(in: root)
        let manager = makeCLIManager(
            homeDirectory: homeDirectory,
            bundleURL: appBundleURL,
            pathDirectories: [outsidePathDirectory]
        )

        let expectedLinkURL = homeDirectory
            .appendingPathComponent(".local/bin", isDirectory: true)
            .appendingPathComponent("omniwmctl", isDirectory: false)
        let result = try manager.installCLIToPATH()

        #expect(result == .installed(linkURL: expectedLinkURL, directoryOnPath: false))
        #expect(manager.exposureStatus() == .appManaged(linkURL: expectedLinkURL, directoryOnPath: false))
    }

    @Test func installCLIIgnoresPathDirectoriesThatOnlyShareHomePrefix() throws {
        let root = makeAppCLIManagerTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)

        let siblingHomePrefixDirectory = root.appendingPathComponent("home-other/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: siblingHomePrefixDirectory, withIntermediateDirectories: true)

        let appBundleURL = try makeBundledCLIAppBundle(in: root)
        let manager = makeCLIManager(
            homeDirectory: homeDirectory,
            bundleURL: appBundleURL,
            pathDirectories: [siblingHomePrefixDirectory]
        )

        let expectedLinkURL = homeDirectory
            .appendingPathComponent(".local/bin", isDirectory: true)
            .appendingPathComponent("omniwmctl", isDirectory: false)
        let result = try manager.installCLIToPATH()

        #expect(result == .installed(linkURL: expectedLinkURL, directoryOnPath: false))
        #expect(FileManager.default.fileExists(atPath: siblingHomePrefixDirectory.appendingPathComponent("omniwmctl").path) == false)
        #expect(manager.exposureStatus() == .appManaged(linkURL: expectedLinkURL, directoryOnPath: false))
    }

    @Test func installAndRemoveCLITrackAppManagedLinkLifecycle() throws {
        let root = makeAppCLIManagerTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        let userBin = homeDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: userBin, withIntermediateDirectories: true)
        let appBundleURL = try makeBundledCLIAppBundle(in: root)
        let manager = makeCLIManager(
            homeDirectory: homeDirectory,
            bundleURL: appBundleURL,
            pathDirectories: [userBin]
        )
        let expectedLinkURL = userBin.appendingPathComponent("omniwmctl", isDirectory: false)

        _ = try manager.installCLIToPATH()
        #expect(try manager.installCLIToPATH() == .alreadyInstalled(linkURL: expectedLinkURL, directoryOnPath: true))
        #expect(try manager.removeInstalledCLI() == .removed(linkURL: expectedLinkURL))
        #expect(try manager.removeInstalledCLI() == .notInstalled(linkURL: expectedLinkURL))
        #expect(FileManager.default.fileExists(atPath: expectedLinkURL.path) == false)
    }

    @Test func homebrewManagedLinkTakesPrecedenceOverAppManagedInstall() throws {
        let root = makeAppCLIManagerTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        let userBin = homeDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: userBin, withIntermediateDirectories: true)
        let homebrewBin = root.appendingPathComponent("homebrew/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: homebrewBin, withIntermediateDirectories: true)
        let appBundleURL = try makeBundledCLIAppBundle(in: root)
        let homebrewLinkURL = homebrewBin.appendingPathComponent("omniwmctl", isDirectory: false)
        try FileManager.default.createSymbolicLink(
            at: homebrewLinkURL,
            withDestinationURL: appBundleURL
                .appendingPathComponent("Contents/MacOS", isDirectory: true)
                .appendingPathComponent("omniwmctl", isDirectory: false)
        )

        let manager = makeCLIManager(
            homeDirectory: homeDirectory,
            bundleURL: appBundleURL,
            pathDirectories: [userBin],
            homebrewLinkURLs: [homebrewLinkURL]
        )

        #expect(manager.exposureStatus() == .homebrewManaged(linkURL: homebrewLinkURL))
        #expect(try manager.installCLIToPATH() == .homebrewManaged(linkURL: homebrewLinkURL))
        #expect(try manager.removeInstalledCLI() == .homebrewManaged(linkURL: homebrewLinkURL))
    }

    @Test func conflictingExistingFileBlocksInstallAndRemoval() throws {
        let root = makeAppCLIManagerTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        let userBin = homeDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: userBin, withIntermediateDirectories: true)
        let appBundleURL = try makeBundledCLIAppBundle(in: root)
        let conflictURL = userBin.appendingPathComponent("omniwmctl", isDirectory: false)
        try Data("not a symlink".utf8).write(to: conflictURL)

        let manager = makeCLIManager(
            homeDirectory: homeDirectory,
            bundleURL: appBundleURL,
            pathDirectories: [userBin]
        )

        #expect(manager.exposureStatus() == .conflict(existingURL: conflictURL))
        #expect(throws: AppCLIInstallError.conflictingInstall(conflictURL)) {
            _ = try manager.installCLIToPATH()
        }
        #expect(throws: AppCLIInstallError.cannotRemoveNonManagedInstall(conflictURL)) {
            _ = try manager.removeInstalledCLI()
        }
    }
}
