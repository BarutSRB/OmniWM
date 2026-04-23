// SPDX-License-Identifier: GPL-2.0-only
import Foundation

enum DefaultFloatingApps {
    static let bundleIds: Set<String> = [
        "com.apple.systempreferences",
        "com.apple.SystemPreferences",
        "com.apple.iphonesimulator",
        "com.apple.PhotoBooth",
        "com.apple.calculator",
        "com.apple.ScreenSharing",
        "com.apple.remotedesktop"
    ]

    static func shouldFloat(_ bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return bundleIds.contains(bundleId)
    }
}
