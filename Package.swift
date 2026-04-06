// swift-tools-version: 6.2
import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
struct BuildMetadata {
    let macOSDeploymentTarget: String
    let requiredZigVersion: String
    let ghosttyArchiveRelativePath: String
    let ghosttyArchiveSHA256: String

    static func load(packageDirectory: String) -> BuildMetadata {
        let metadataURL = URL(fileURLWithPath: packageDirectory).appendingPathComponent("Scripts/build-metadata.env")
        guard let contents = try? String(contentsOf: metadataURL, encoding: .utf8) else {
            fatalError("Missing build metadata at \(metadataURL.path)")
        }

        var values: [String: String] = [:]
        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            guard let separatorIndex = line.firstIndex(of: "=") else {
                fatalError("Invalid build metadata line: \(line)")
            }

            let key = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespaces)
            let valueStart = line.index(after: separatorIndex)
            let value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
            values[key] = value
        }

        func require(_ key: String) -> String {
            guard let value = values[key], !value.isEmpty else {
                fatalError("Missing \(key) in \(metadataURL.path)")
            }
            return value
        }

        return BuildMetadata(
            macOSDeploymentTarget: require("OMNIWM_MACOS_DEPLOYMENT_TARGET"),
            requiredZigVersion: require("OMNIWM_REQUIRED_ZIG_VERSION"),
            ghosttyArchiveRelativePath: require("OMNIWM_GHOSTTY_ARCHIVE_RELATIVE_PATH"),
            ghosttyArchiveSHA256: require("OMNIWM_GHOSTTY_ARCHIVE_SHA256")
        )
    }
}

let buildMetadata = BuildMetadata.load(packageDirectory: packageDirectory)
let ghosttyArchiveURL = URL(fileURLWithPath: packageDirectory).appendingPathComponent(buildMetadata.ghosttyArchiveRelativePath)
let ghosttyMacOSLibraryDirectory = ghosttyArchiveURL.deletingLastPathComponent().path
let zigKernelLibraryDirectory = "\(packageDirectory)/.build/zig-kernels/lib"

let package = Package(
    name: "OmniWM",
    platforms: [
        .macOS(buildMetadata.macOSDeploymentTarget)
    ],
    products: [
        .executable(
            name: "OmniWM",
            targets: ["OmniWMApp"]
        ),
        .executable(
            name: "omniwmctl",
            targets: ["OmniWMCtl"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "Frameworks/GhosttyKit.xcframework"
        ),
        .target(
            name: "COmniWMKernels",
            path: "Sources/COmniWMKernels",
            publicHeadersPath: "include"
        ),
        .target(
            name: "OmniWMIPC",
            path: "Sources/OmniWMIPC",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "OmniWM",
            dependencies: ["GhosttyKit", "OmniWMIPC", "COmniWMKernels"],
            path: "Sources/OmniWM",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .interoperabilityMode(.C),
                .unsafeFlags(["-enable-testing"])
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedLibrary("omniwm_kernels"),
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
                .unsafeFlags(["-L\(zigKernelLibraryDirectory)"]),
                .unsafeFlags(["-L\(ghosttyMacOSLibraryDirectory)"]),
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"])
            ]
        ),
        .executableTarget(
            name: "OmniWMApp",
            dependencies: ["OmniWM"],
            path: "Sources/OmniWMApp",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "OmniWMCtl",
            dependencies: ["OmniWMIPC"],
            path: "Sources/OmniWMCtl",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "OmniWMTests",
            dependencies: ["OmniWM", "OmniWMIPC", "OmniWMCtl"],
            path: "Tests/OmniWMTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
