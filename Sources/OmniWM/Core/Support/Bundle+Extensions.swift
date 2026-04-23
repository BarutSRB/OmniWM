// SPDX-License-Identifier: GPL-2.0-only
import Foundation

extension Bundle {
    var appVersion: String? { infoDictionary?["CFBundleShortVersionString"] as? String }
    var releaseVersion: ReleaseVersion? { appVersion.flatMap(ReleaseVersion.init) }
}
