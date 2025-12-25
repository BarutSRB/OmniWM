import SwiftUI

struct RunningAppInfo: Identifiable {
    let id: String
    let bundleId: String
    let appName: String
    let icon: NSImage?
    let windowSize: CGSize
}

struct AppRulesView: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    @State private var editingRule: AppRule?
    @State private var isAddingNew = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("App Rules")
                    .font(.headline)
                Spacer()
                Button(action: { isAddingNew = true }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .help("Add app rule")
            }
            .padding()

            Divider()

            if settings.appRules.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "app.badge.checkmark")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No app rules configured")
                        .foregroundColor(.secondary)
                    Text("Add rules to control per-app behavior:\nfloating, workspace assignment, and minimum size.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(settings.appRules) { rule in
                        AppRuleRow(
                            rule: rule,
                            onEdit: { editingRule = rule },
                            onDelete: { deleteRule(rule) }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 450, minHeight: 350)
        .sheet(item: $editingRule) { rule in
            AppRuleEditSheet(
                rule: rule,
                isNew: false,
                existingBundleIds: existingBundleIds(excluding: rule.bundleId),
                workspaceNames: workspaceNames,
                controller: controller,
                onSave: { updated in
                    updateRule(updated)
                    editingRule = nil
                },
                onCancel: { editingRule = nil }
            )
        }
        .sheet(isPresented: $isAddingNew) {
            AppRuleEditSheet(
                rule: AppRule(bundleId: ""),
                isNew: true,
                existingBundleIds: existingBundleIds(excluding: nil),
                workspaceNames: workspaceNames,
                controller: controller,
                onSave: { newRule in
                    addRule(newRule)
                    isAddingNew = false
                },
                onCancel: { isAddingNew = false }
            )
        }
    }

    private var workspaceNames: [String] {
        settings.workspaceConfigurations.map(\.name)
    }

    private func existingBundleIds(excluding: String?) -> Set<String> {
        Set(settings.appRules.map(\.bundleId).filter { $0 != excluding })
    }

    private func addRule(_ rule: AppRule) {
        settings.appRules.append(rule)
        controller.updateAppRules()
    }

    private func updateRule(_ rule: AppRule) {
        if let index = settings.appRules.firstIndex(where: { $0.id == rule.id }) {
            settings.appRules[index] = rule
            controller.updateAppRules()
        }
    }

    private func deleteRule(_ rule: AppRule) {
        settings.appRules.removeAll { $0.id == rule.id }
        controller.updateAppRules()
    }
}

struct AppRuleRow: View {
    let rule: AppRule
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.bundleId)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if rule.alwaysFloat == true {
                        RuleBadge(text: "Float", color: .blue)
                    }
                    if let ws = rule.assignToWorkspace {
                        RuleBadge(text: "WS: \(ws)", color: .green)
                    }
                    if rule.minWidth != nil || rule.minHeight != nil {
                        let sizeText = formatMinSize(rule.minWidth, rule.minHeight)
                        RuleBadge(text: sizeText, color: .orange)
                    }
                }
            }

            Spacer()

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private func formatMinSize(_ w: Double?, _ h: Double?) -> String {
        switch (w, h) {
        case let (w?, h?): "Min: \(Int(w))x\(Int(h))"
        case let (w?, nil): "Min W: \(Int(w))"
        case let (nil, h?): "Min H: \(Int(h))"
        default: ""
        }
    }
}

struct RuleBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(4)
    }
}

struct RunningAppRow: View {
    let app: RunningAppInfo
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "app")
                        .frame(width: 20, height: 20)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.appName)
                        .font(.body)
                        .foregroundColor(.primary)
                    Text(app.bundleId)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text("\(Int(app.windowSize.width))x\(Int(app.windowSize.height))")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

struct AppRuleEditSheet: View {
    @State private var rule: AppRule
    let isNew: Bool
    let existingBundleIds: Set<String>
    let workspaceNames: [String]
    let controller: WMController
    let onSave: (AppRule) -> Void
    let onCancel: () -> Void

    @State private var bundleIdError: String?
    @State private var alwaysFloatEnabled: Bool
    @State private var workspaceEnabled: Bool
    @State private var minWidthEnabled: Bool
    @State private var minHeightEnabled: Bool

    @State private var runningApps: [RunningAppInfo] = []
    @State private var isPickerExpanded = false
    @State private var selectedAppInfo: RunningAppInfo?

    init(
        rule: AppRule,
        isNew: Bool,
        existingBundleIds: Set<String>,
        workspaceNames: [String],
        controller: WMController,
        onSave: @escaping (AppRule) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _rule = State(initialValue: rule)
        self.isNew = isNew
        self.existingBundleIds = existingBundleIds
        self.workspaceNames = workspaceNames
        self.controller = controller
        self.onSave = onSave
        self.onCancel = onCancel
        _alwaysFloatEnabled = State(initialValue: rule.alwaysFloat == true)
        _workspaceEnabled = State(initialValue: rule.assignToWorkspace != nil)
        _minWidthEnabled = State(initialValue: rule.minWidth != nil)
        _minHeightEnabled = State(initialValue: rule.minHeight != nil)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(isNew ? "Add App Rule" : "Edit App Rule")
                .font(.headline)

            Form {
                Section("Application") {
                    TextField("Bundle ID", text: $rule.bundleId)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: rule.bundleId) { _, newValue in
                            validateBundleId(newValue)
                        }
                    if let error = bundleIdError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    DisclosureGroup("Pick from running apps", isExpanded: $isPickerExpanded) {
                        if runningApps.isEmpty {
                            Text("No apps with windows found")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 4) {
                                    ForEach(runningApps) { app in
                                        RunningAppRow(
                                            app: app,
                                            isSelected: rule.bundleId == app.bundleId,
                                            onSelect: {
                                                selectApp(app)
                                            }
                                        )
                                    }
                                }
                            }
                            .frame(maxHeight: 200)
                        }
                    }
                    .onAppear {
                        runningApps = controller.runningAppsWithWindows()
                            .filter { !existingBundleIds.contains($0.bundleId) }
                    }

                    if let appInfo = selectedAppInfo {
                        Button(action: {
                            useCurrentWindowSize(appInfo.windowSize)
                        }) {
                            HStack {
                                Image(systemName: "arrow.down.doc")
                                Text(
                                    "Use current size: \(Int(appInfo.windowSize.width)) x \(Int(appInfo.windowSize.height)) px"
                                )
                            }
                        }
                        .buttonStyle(.bordered)
                    }

                    Text("Example: com.apple.finder")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Window Behavior") {
                    Toggle("Always Float", isOn: $alwaysFloatEnabled)
                        .onChange(of: alwaysFloatEnabled) { _, enabled in
                            rule.alwaysFloat = enabled ? true : nil
                        }

                    Toggle("Assign to Workspace", isOn: $workspaceEnabled)
                        .onChange(of: workspaceEnabled) { _, enabled in
                            if !enabled {
                                rule.assignToWorkspace = nil
                            } else if rule.assignToWorkspace == nil, let first = workspaceNames.first {
                                rule.assignToWorkspace = first
                            }
                        }

                    if workspaceEnabled {
                        Picker("Workspace", selection: Binding(
                            get: { rule.assignToWorkspace ?? "" },
                            set: { rule.assignToWorkspace = $0.isEmpty ? nil : $0 }
                        )) {
                            ForEach(workspaceNames, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .disabled(workspaceNames.isEmpty)

                        if workspaceNames.isEmpty {
                            Text("No workspaces configured. Add workspaces in Settings.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("Minimum Size (Layout Constraint)") {
                    Toggle("Minimum Width", isOn: $minWidthEnabled)
                        .onChange(of: minWidthEnabled) { _, enabled in
                            rule.minWidth = enabled ? (rule.minWidth ?? 400) : nil
                        }

                    if minWidthEnabled {
                        HStack {
                            TextField("Width", value: Binding(
                                get: { rule.minWidth ?? 400 },
                                set: { rule.minWidth = $0 }
                            ), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Text("px")
                                .foregroundColor(.secondary)
                        }
                    }

                    Toggle("Minimum Height", isOn: $minHeightEnabled)
                        .onChange(of: minHeightEnabled) { _, enabled in
                            rule.minHeight = enabled ? (rule.minHeight ?? 300) : nil
                        }

                    if minHeightEnabled {
                        HStack {
                            TextField("Height", value: Binding(
                                get: { rule.minHeight ?? 300 },
                                set: { rule.minHeight = $0 }
                            ), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Text("px")
                                .foregroundColor(.secondary)
                        }
                    }

                    Text("Prevents layout engine from sizing window smaller than these values.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(isNew ? "Add" : "Save") {
                    onSave(rule)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding()
        .frame(minWidth: 400)
    }

    private var isValid: Bool {
        !rule.bundleId.isEmpty && bundleIdError == nil && rule.hasAnyRule
    }

    private func validateBundleId(_ bundleId: String) {
        if bundleId.isEmpty {
            bundleIdError = nil
            return
        }

        if existingBundleIds.contains(bundleId) {
            bundleIdError = "A rule for this bundle ID already exists"
            return
        }

        let regex = try? NSRegularExpression(pattern: "^[a-zA-Z][a-zA-Z0-9-]*(\\.[a-zA-Z0-9-]+)+$")
        let range = NSRange(bundleId.startIndex..., in: bundleId)
        if regex?.firstMatch(in: bundleId, range: range) == nil {
            bundleIdError = "Invalid bundle ID format"
            return
        }

        bundleIdError = nil
    }

    private func selectApp(_ app: RunningAppInfo) {
        rule.bundleId = app.bundleId
        selectedAppInfo = app
        isPickerExpanded = false
        validateBundleId(app.bundleId)
    }

    private func useCurrentWindowSize(_ size: CGSize) {
        rule.minWidth = size.width
        rule.minHeight = size.height
        minWidthEnabled = true
        minHeightEnabled = true
    }
}
