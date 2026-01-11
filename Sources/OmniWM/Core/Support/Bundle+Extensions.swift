import Foundation

extension Bundle {
    var appName: String { infoDictionary?["CFBundleName"] as? String ?? "OmniWM" }
    var appVersion: String? { infoDictionary?["CFBundleShortVersionString"] as? String }
    var appBuild: Int? { Int(infoDictionary?["CFBundleVersion"] as? String ?? "") }
    var bundleID: String { bundleIdentifier ?? "com.omniwm.app" }
}
