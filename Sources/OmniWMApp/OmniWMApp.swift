// SPDX-License-Identifier: GPL-2.0-only
import AppKit
@testable import OmniWM
import SwiftUI

@main
struct OmniWMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var bootstrap: AppBootstrapState

    init() {
        let bootstrap = AppBootstrapState()
        _bootstrap = State(wrappedValue: bootstrap)
        AppDelegate.sharedBootstrap = bootstrap
    }

    var body: some Scene {
        Settings {
            SettingsSceneRedirectView(bootstrap: bootstrap)
        }
    }
}
