import SwiftUI

struct MonitorSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var selectedMonitor: String?
    @State private var connectedMonitors: [Monitor] = Monitor.current()

    var body: some View {
        Form {
            Section {
                Picker("Monitor:", selection: $selectedMonitor) {
                    if connectedMonitors.isEmpty {
                        Text("No monitors detected").tag(nil as String?)
                    } else {
                        ForEach(connectedMonitors, id: \.name) { monitor in
                            HStack {
                                Text(monitor.name)
                                if monitor.isMain {
                                    Text("(Main)").foregroundColor(.secondary)
                                }
                            }
                            .tag(monitor.name as String?)
                        }
                    }
                }
                .pickerStyle(.menu)
            }

            if let monitorName = selectedMonitor,
               let monitor = connectedMonitors.first(where: { $0.name == monitorName }) {
                MonitorOrientationSection(
                    settings: settings,
                    controller: controller,
                    monitor: monitor
                )
            } else {
                Section {
                    Text("Select a monitor to configure its orientation.")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .onAppear {
            connectedMonitors = Monitor.current()
            if selectedMonitor == nil, let first = connectedMonitors.first {
                selectedMonitor = first.name
            }
        }
    }
}

private struct MonitorOrientationSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let monitor: Monitor

    private var orientationOverride: Monitor.Orientation? {
        settings.orientationSettings(for: monitor.name)?.orientation
    }

    private var effectiveOrientation: Monitor.Orientation {
        settings.effectiveOrientation(for: monitor)
    }

    var body: some View {
        Section("Orientation") {
            HStack {
                Text("Auto-detected:")
                Spacer()
                Text(monitor.autoOrientation.displayName)
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Current:")
                Spacer()
                Text(effectiveOrientation.displayName)
                    .fontWeight(.medium)
            }

            Divider()

            Picker("Override:", selection: Binding(
                get: { orientationOverride },
                set: { newValue in
                    updateOrientation(newValue)
                }
            )) {
                Text("Auto").tag(nil as Monitor.Orientation?)
                Text("Horizontal").tag(Monitor.Orientation.horizontal as Monitor.Orientation?)
                Text("Vertical").tag(Monitor.Orientation.vertical as Monitor.Orientation?)
            }
            .pickerStyle(.segmented)

            if orientationOverride != nil {
                HStack {
                    Spacer()
                    Button("Reset to Auto") {
                        updateOrientation(nil)
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
            }

            Text("Override the auto-detected orientation for this monitor. Vertical monitors scroll windows top-to-bottom instead of left-to-right.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func updateOrientation(_ orientation: Monitor.Orientation?) {
        let newSettings = MonitorOrientationSettings(
            monitorName: monitor.name,
            orientation: orientation
        )
        if orientation == nil {
            settings.removeOrientationSettings(for: monitor.name)
        } else {
            settings.updateOrientationSettings(newSettings)
        }
        controller.updateMonitorOrientations()
    }
}

extension Monitor.Orientation {
    var displayName: String {
        switch self {
        case .horizontal: "Horizontal"
        case .vertical: "Vertical"
        }
    }
}
