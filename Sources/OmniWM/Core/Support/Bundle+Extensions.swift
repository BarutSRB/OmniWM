import Foundation

extension Bundle {
    var appVersion: String? { infoDictionary?["CFBundleShortVersionString"] as? String }
}
