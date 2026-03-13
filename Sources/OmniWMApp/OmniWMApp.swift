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
            if let settings = bootstrap.settings,
               let controller = bootstrap.controller {
                SettingsView(settings: settings, controller: controller)
                    .frame(minWidth: 480, minHeight: 500)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Starting OmniWM…")
                        .foregroundColor(.secondary)
                }
                .frame(minWidth: 480, minHeight: 500)
            }
        }
    }
}
