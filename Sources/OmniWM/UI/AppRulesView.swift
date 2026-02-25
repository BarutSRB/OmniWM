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

    @State private var selectedRuleId: AppRule.ID?
    @State private var isAddingNew = false

    var body: some View {
        NavigationSplitView {
            AppRulesSidebar(
                rules: settings.appRules,
                selection: $selectedRuleId,
                onAdd: { isAddingNew = true },
                onDelete: deleteRule
            )
        } detail: {
            if let ruleId = selectedRuleId,
               let ruleIndex = settings.appRules.firstIndex(where: { $0.id == ruleId })
            {
                AppRuleDetailView(
                    rule: $settings.appRules[ruleIndex],
                    workspaceNames: workspaceNames,
                    controller: controller,
                    onDelete: {
                        deleteRule(settings.appRules[ruleIndex])
                        selectedRuleId = nil
                    }
                )
                .id(ruleId)
                .omniBackgroundExtensionEffect()
            } else {
                AppRulesEmptyState(onAdd: { isAddingNew = true })
                    .omniBackgroundExtensionEffect()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $isAddingNew) {
            AppRuleAddSheet(
                existingBundleIds: existingBundleIds,
                workspaceNames: workspaceNames,
                controller: controller,
                onSave: { newRule in
                    settings.appRules.append(newRule)
                    controller.updateAppRules()
                    selectedRuleId = newRule.id
                    isAddingNew = false
                },
                onCancel: { isAddingNew = false }
            )
        }
        .frame(minWidth: 580, minHeight: 400)
    }

    private var workspaceNames: [String] {
        settings.workspaceConfigurations.map(\.name)
    }

    private var existingBundleIds: Set<String> {
        Set(settings.appRules.map(\.bundleId))
    }

    private func deleteRule(_ rule: AppRule) {
        settings.appRules.removeAll { $0.id == rule.id }
        controller.updateAppRules()
        if selectedRuleId == rule.id {
            selectedRuleId = nil
        }
    }
}

struct AppRulesSidebar: View {
    let rules: [AppRule]
    @Binding var selection: AppRule.ID?
    let onAdd: () -> Void
    let onDelete: (AppRule) -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(rules) { rule in
                AppRuleSidebarRow(rule: rule)
                    .tag(rule.id)
                    .contextMenu {
                        Button(role: .destructive) {
                            onDelete(rule)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("App Rules")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                }
                .help("Add app rule")
            }
        }
    }
}

struct AppRuleSidebarRow: View {
    let rule: AppRule

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(rule.bundleId)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)

            HStack(spacing: 4) {
                if rule.alwaysFloat == true {
                    RuleBadge(text: "Float", color: .blue)
                }
                if rule.assignToWorkspace != nil {
                    RuleBadge(text: "WS", color: .green)
                }
                if rule.minWidth != nil || rule.minHeight != nil {
                    RuleBadge(text: "Size", color: .orange)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct AppRulesEmptyState: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "app.badge.checkmark")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No App Rule Selected")
                .font(.headline)
            Text("Select an app rule from the sidebar to edit it,\nor add a new rule to get started.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Rule", action: onAdd)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AppRuleDetailView: View {
    @Binding var rule: AppRule
    let workspaceNames: [String]
    let controller: WMController
    let onDelete: () -> Void

    @State private var alwaysFloatEnabled: Bool
    @State private var workspaceEnabled: Bool
    @State private var minWidthEnabled: Bool
    @State private var minHeightEnabled: Bool

    init(
        rule: Binding<AppRule>,
        workspaceNames: [String],
        controller: WMController,
        onDelete: @escaping () -> Void
    ) {
        _rule = rule
        self.workspaceNames = workspaceNames
        self.controller = controller
        self.onDelete = onDelete
        _alwaysFloatEnabled = State(initialValue: rule.wrappedValue.alwaysFloat == true)
        _workspaceEnabled = State(initialValue: rule.wrappedValue.assignToWorkspace != nil)
        _minWidthEnabled = State(initialValue: rule.wrappedValue.minWidth != nil)
        _minHeightEnabled = State(initialValue: rule.wrappedValue.minHeight != nil)
    }

    var body: some View {
        ScrollView {
            Form {
                Section("Application") {
                    LabeledContent("Bundle ID") {
                        Text(rule.bundleId)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                Section("Window Behavior") {
                    Toggle("Always Float", isOn: $alwaysFloatEnabled)
                        .onChange(of: alwaysFloatEnabled) { _, enabled in
                            rule.alwaysFloat = enabled ? true : nil
                            controller.updateAppRules()
                        }

                    Toggle("Assign to Workspace", isOn: $workspaceEnabled)
                        .onChange(of: workspaceEnabled) { _, enabled in
                            if !enabled {
                                rule.assignToWorkspace = nil
                            } else if rule.assignToWorkspace == nil, let first = workspaceNames.first {
                                rule.assignToWorkspace = first
                            }
                            controller.updateAppRules()
                        }

                    if workspaceEnabled {
                        Picker("Workspace", selection: Binding(
                            get: { rule.assignToWorkspace ?? "" },
                            set: {
                                rule.assignToWorkspace = $0.isEmpty ? nil : $0
                                controller.updateAppRules()
                            }
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
                            controller.updateAppRules()
                        }

                    if minWidthEnabled {
                        HStack {
                            TextField("Width", value: Binding(
                                get: { rule.minWidth ?? 400 },
                                set: {
                                    rule.minWidth = $0
                                    controller.updateAppRules()
                                }
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
                            controller.updateAppRules()
                        }

                    if minHeightEnabled {
                        HStack {
                            TextField("Height", value: Binding(
                                get: { rule.minHeight ?? 300 },
                                set: {
                                    rule.minHeight = $0
                                    controller.updateAppRules()
                                }
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

                Section {
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete Rule", systemImage: "trash")
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
        }
    }
}

struct AppRuleAddSheet: View {
    let existingBundleIds: Set<String>
    let workspaceNames: [String]
    let controller: WMController
    let onSave: (AppRule) -> Void
    let onCancel: () -> Void

    @State private var rule = AppRule(bundleId: "")
    @State private var bundleIdError: String?
    @State private var alwaysFloatEnabled = false
    @State private var workspaceEnabled = false
    @State private var minWidthEnabled = false
    @State private var minHeightEnabled = false
    @State private var runningApps: [RunningAppInfo] = []
    @State private var isPickerExpanded = true
    @State private var selectedAppInfo: RunningAppInfo?

    var body: some View {
        VStack(spacing: 16) {
            Text("Add App Rule")
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
                                            onSelect: { selectApp(app) }
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
                        Button {
                            useCurrentWindowSize(appInfo.windowSize)
                        } label: {
                            HStack {
                                Image(systemName: "arrow.down.doc")
                                Text("Use current size: \(Int(appInfo.windowSize.width)) x \(Int(appInfo.windowSize.height)) px")
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

                Button("Add") {
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
            .clipShape(RoundedRectangle(cornerRadius: 4))
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
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
