import SwiftUI

struct MonitorSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var selectedMonitor: Monitor.ID?
    @State private var connectedMonitors: [Monitor] = Monitor.current()

    var body: some View {
        Form {
            MouseWarpSection(settings: settings, controller: controller, connectedMonitors: connectedMonitors)

            Section {
                Picker("Monitor:", selection: $selectedMonitor) {
                    if connectedMonitors.isEmpty {
                        Text("No monitors detected").tag(nil as Monitor.ID?)
                    } else {
                        ForEach(connectedMonitors, id: \.id) { monitor in
                            HStack {
                                Text(monitor.name)
                                if monitor.isMain {
                                    Text("(Main)").foregroundColor(.secondary)
                                }
                            }
                            .tag(monitor.id as Monitor.ID?)
                        }
                    }
                }
                .pickerStyle(.menu)
            }

            if let monitorId = selectedMonitor,
               let monitor = connectedMonitors.first(where: { $0.id == monitorId })
            {
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
        .formStyle(.grouped)
        .onAppear {
            connectedMonitors = Monitor.current()
            if selectedMonitor == nil, let first = connectedMonitors.first {
                selectedMonitor = first.id
            }
        }
    }
}

private struct MonitorOrientationSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let monitor: Monitor

    private var orientationOverride: Monitor.Orientation? {
        settings.orientationSettings(for: monitor)?.orientation
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

            Text(
                "Override the auto-detected orientation for this monitor. Vertical monitors scroll windows top-to-bottom instead of left-to-right."
            )
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    private func updateOrientation(_ orientation: Monitor.Orientation?) {
        let newSettings = MonitorOrientationSettings(
            monitorName: monitor.name,
            monitorDisplayId: monitor.displayId,
            orientation: orientation
        )
        if orientation == nil {
            settings.removeOrientationSettings(for: monitor)
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

private struct MouseWarpSection: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let connectedMonitors: [Monitor]

    private var orderedMonitors: [String] {
        if settings.mouseWarpMonitorOrder.isEmpty {
            return connectedMonitors.map(\.name)
        }
        let known = Set(connectedMonitors.map(\.name))
        return settings.mouseWarpMonitorOrder.filter { known.contains($0) }
    }

    var body: some View {
        Section("Mouse Warp") {
            Toggle("Enable Mouse Warp", isOn: Binding(
                get: { settings.mouseWarpEnabled },
                set: { newValue in
                    settings.mouseWarpEnabled = newValue
                    controller.setMouseWarpEnabled(newValue)
                }
            ))

            if settings.mouseWarpEnabled {
                Text("Drag monitors to arrange in physical left-to-right order:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(spacing: 4) {
                    ForEach(Array(orderedMonitors.enumerated()), id: \.element) { index, name in
                        HStack {
                            Text("\(index + 1).")
                                .foregroundColor(.secondary)
                                .frame(width: 20, alignment: .trailing)
                            Text(name)
                            Spacer()
                            if connectedMonitors.first(where: { $0.name == name })?.isMain == true {
                                Text("Main")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            HStack(spacing: 4) {
                                Button {
                                    moveUp(index)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .disabled(index == 0)
                                .buttonStyle(.borderless)

                                Button {
                                    moveDown(index)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .disabled(index == orderedMonitors.count - 1)
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                    }
                }

                Stepper(value: Binding(
                    get: { settings.mouseWarpMargin },
                    set: { settings.mouseWarpMargin = $0 }
                ), in: 1...10) {
                    HStack {
                        Text("Edge Margin:")
                        Spacer()
                        Text("\(settings.mouseWarpMargin) px")
                            .foregroundColor(.secondary)
                    }
                }
            }

            Text(
                "When enabled, the mouse cursor warps between monitors when it hits the screen edge, simulating horizontal arrangement for vertically-stacked displays."
            )
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    private func moveUp(_ index: Int) {
        guard index > 0 else { return }
        var order = orderedMonitors
        order.swapAt(index, index - 1)
        settings.mouseWarpMonitorOrder = order
    }

    private func moveDown(_ index: Int) {
        guard index < orderedMonitors.count - 1 else { return }
        var order = orderedMonitors
        order.swapAt(index, index + 1)
        settings.mouseWarpMonitorOrder = order
    }
}
