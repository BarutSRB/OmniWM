import SwiftUI

struct WorkspacesSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    @State private var editingConfig: WorkspaceConfiguration?
    @State private var isAddingNew = false
    @State private var connectedMonitors: [Monitor] = Monitor.current()

    var body: some View {
        Form {
            Section("Default Layout") {
                Picker("Layout Algorithm", selection: $settings.defaultLayoutType) {
                    ForEach(LayoutType.allCases.filter { $0 != .defaultLayout }) { layout in
                        Text(layout.displayName).tag(layout)
                    }
                }
                .onChange(of: settings.defaultLayoutType) { _, _ in
                    controller.updateWorkspaceConfig()
                }
            }

            Section {
                if settings.workspaceConfigurations.isEmpty {
                    Text("No workspaces configured")
                        .foregroundColor(.secondary)
                        .italic()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    ForEach(settings.workspaceConfigurations) { config in
                        WorkspaceConfigurationRow(
                            configuration: config,
                            connectedMonitors: connectedMonitors,
                            onEdit: { editingConfig = config },
                            onDelete: { deleteConfiguration(config) }
                        )
                    }
                }
            } header: {
                HStack {
                    Text("Workspace Configurations")
                    Spacer()
                    Button(action: { isAddingNew = true }) {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Add workspace configuration")
                }
            } footer: {
                Text("Configure workspace name, monitor assignment, layout, and persistence.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .sheet(item: $editingConfig) { config in
            WorkspaceEditSheet(
                configuration: config,
                isNew: false,
                existingNames: existingNames(excluding: config.name),
                connectedMonitors: connectedMonitors,
                onSave: { updated in
                    updateConfiguration(updated)
                    editingConfig = nil
                },
                onCancel: { editingConfig = nil }
            )
        }
        .sheet(isPresented: $isAddingNew) {
            WorkspaceEditSheet(
                configuration: WorkspaceConfiguration(name: ""),
                isNew: true,
                existingNames: existingNames(excluding: nil),
                connectedMonitors: connectedMonitors,
                onSave: { newConfig in
                    addConfiguration(newConfig)
                    isAddingNew = false
                },
                onCancel: { isAddingNew = false }
            )
        }
    }

    private func existingNames(excluding: String?) -> Set<String> {
        Set(settings.workspaceConfigurations.map(\.name).filter { $0 != excluding })
    }

    private func addConfiguration(_ config: WorkspaceConfiguration) {
        settings.workspaceConfigurations.append(config)
        controller.updateWorkspaceConfig()
    }

    private func updateConfiguration(_ config: WorkspaceConfiguration) {
        if let index = settings.workspaceConfigurations.firstIndex(where: { $0.id == config.id }) {
            settings.workspaceConfigurations[index] = config
            controller.updateWorkspaceConfig()
        }
    }

    private func deleteConfiguration(_ config: WorkspaceConfiguration) {
        settings.workspaceConfigurations.removeAll { $0.id == config.id }
        controller.updateWorkspaceConfig()
    }
}

struct WorkspaceConfigurationRow: View {
    let configuration: WorkspaceConfiguration
    let connectedMonitors: [Monitor]
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(configuration.name)
                    .font(.body.weight(.medium))
                if configuration.isPersistent {
                    Text("Persistent")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(minWidth: 60, alignment: .leading)

            Divider()
                .frame(height: 24)

            Text(monitorDisplayName(configuration.monitorAssignment))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(minWidth: 70, alignment: .leading)

            Divider()
                .frame(height: 24)

            Text(configuration.layoutType.displayName)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(4)

            Spacer()

            Button(action: onEdit) {
                Image(systemName: "pencil.circle")
            }
            .buttonStyle(.plain)
            .help("Edit workspace configuration")

            Button(action: onDelete) {
                Image(systemName: "trash.circle")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .help("Delete workspace configuration")
        }
        .padding(.vertical, 4)
    }

    private func monitorDisplayName(_ assignment: MonitorAssignment) -> String {
        switch assignment {
        case .any:
            return "Any"
        case .main:
            return "Main"
        case .secondary:
            return "Secondary"
        case let .numbered(n):
            if n > 0, n <= connectedMonitors.count {
                return connectedMonitors[n - 1].name
            }
            return "Monitor \(n)"
        case let .pattern(p):
            return "Pattern: \(p)"
        }
    }
}

struct WorkspaceEditSheet: View {
    @State private var configuration: WorkspaceConfiguration
    let isNew: Bool
    let existingNames: Set<String>
    let connectedMonitors: [Monitor]
    let onSave: (WorkspaceConfiguration) -> Void
    let onCancel: () -> Void

    @State private var nameError: String?
    @State private var customPattern: String = ""
    @State private var useCustomPattern: Bool = false

    init(
        configuration: WorkspaceConfiguration,
        isNew: Bool,
        existingNames: Set<String>,
        connectedMonitors: [Monitor],
        onSave: @escaping (WorkspaceConfiguration) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _configuration = State(initialValue: configuration)
        self.isNew = isNew
        self.existingNames = existingNames
        self.connectedMonitors = connectedMonitors
        self.onSave = onSave
        self.onCancel = onCancel

        if case let .pattern(p) = configuration.monitorAssignment {
            _customPattern = State(initialValue: p)
            _useCustomPattern = State(initialValue: true)
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(isNew ? "Add Workspace" : "Edit Workspace")
                .font(.headline)

            Form {
                TextField("Workspace Name", text: $configuration.name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: configuration.name) { _, newValue in
                        validateName(newValue)
                    }
                if let error = nameError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Picker("Monitor", selection: monitorSelectionBinding) {
                    Text("Any").tag(MonitorAssignment.any)
                    Text("Main").tag(MonitorAssignment.main)
                    Text("Secondary").tag(MonitorAssignment.secondary)
                    Divider()
                    ForEach(Array(connectedMonitors.enumerated()), id: \.element.id) { index, monitor in
                        HStack {
                            Text(monitor.name)
                            if monitor.isMain {
                                Text("(Main)").foregroundColor(.secondary)
                            }
                        }
                        .tag(MonitorAssignment.numbered(index + 1))
                    }
                    Divider()
                    Text("Custom Pattern...")
                        .tag(MonitorAssignment.pattern(customPattern.isEmpty ? " " : customPattern))
                }

                if useCustomPattern {
                    TextField("Monitor Name Pattern (regex)", text: $customPattern)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: customPattern) { _, newValue in
                            configuration.monitorAssignment = .pattern(newValue)
                        }
                }

                Picker("Layout", selection: $configuration.layoutType) {
                    ForEach(LayoutType.allCases) { layout in
                        Text(layout.displayName).tag(layout)
                    }
                }

                Toggle("Keep workspace alive when empty", isOn: $configuration.isPersistent)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(isNew ? "Add" : "Save") {
                    onSave(configuration)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding()
        .frame(minWidth: 350)
    }

    private var monitorSelectionBinding: Binding<MonitorAssignment> {
        Binding(
            get: { configuration.monitorAssignment },
            set: { newValue in
                if case .pattern = newValue {
                    useCustomPattern = true
                    if customPattern.isEmpty {
                        customPattern = ""
                    }
                    configuration.monitorAssignment = .pattern(customPattern)
                } else {
                    useCustomPattern = false
                    configuration.monitorAssignment = newValue
                }
            }
        )
    }

    private var isValid: Bool {
        !configuration.name.isEmpty && nameError == nil
    }

    private func validateName(_ name: String) {
        if name.isEmpty {
            nameError = nil
            return
        }

        if existingNames.contains(name) {
            nameError = "A workspace with this name already exists"
            return
        }

        switch WorkspaceName.parse(name) {
        case .success:
            nameError = nil
        case let .failure(error):
            nameError = error.message
        }
    }
}
