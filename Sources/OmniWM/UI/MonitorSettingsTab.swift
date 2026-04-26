import AppKit
import SwiftUI

struct MonitorSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    @State private var selectedMonitor: Monitor.ID?
    @State private var connectedMonitors: [Monitor] = Monitor.current()

    private var warpAxis: MouseWarpAxis {
        settings.mouseWarpAxis
    }

    private var sortedMonitors: [Monitor] {
        MonitorSettingsTabModel.sortedMonitors(connectedMonitors, axis: warpAxis)
    }

    private var displayLabels: [Monitor.ID: MonitorDisplayLabel] {
        MonitorSettingsTabModel.displayLabels(for: sortedMonitors, axis: warpAxis)
    }

    private var warpOrderEntries: [MonitorOrderEntry] {
        MonitorSettingsTabModel.orderEntries(
            for: sortedMonitors,
            orderedNames: settings.effectiveMouseWarpMonitorOrder(for: sortedMonitors, axis: warpAxis),
            axis: warpAxis
        )
    }

    private var effectiveSelectedMonitorID: Monitor.ID? {
        MonitorSettingsTabModel.normalizedSelection(selectedMonitor, entries: warpOrderEntries)
    }

    private var selectedConnectedMonitor: Monitor? {
        guard let monitorID = effectiveSelectedMonitorID else { return nil }
        return sortedMonitors.first(where: { $0.id == monitorID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader("Selected Monitor")

            if let monitor = selectedConnectedMonitor,
               let displayLabel = displayLabels[monitor.id]
            {
                SelectedMonitorDetails(
                    settings: settings,
                    controller: controller,
                    monitor: monitor,
                    displayLabel: displayLabel
                )
            } else if sortedMonitors.isEmpty {
                Text("No monitors detected.")
                    .foregroundColor(.secondary)
            } else {
                Text("Select a monitor from the strip above to configure its orientation.")
                    .foregroundColor(.secondary)
            }

            Divider()

            SectionHeader("Mouse Warp")

            VStack(alignment: .leading, spacing: 12) {
                Picker("Warp Axis", selection: Binding(
                    get: { settings.mouseWarpAxis },
                    set: { settings.mouseWarpAxis = $0 }
                )) {
                    ForEach(MouseWarpAxis.allCases, id: \.self) { axis in
                        Text(axis.displayName).tag(axis)
                    }
                }
                .pickerStyle(.segmented)

                Text(
                    "Choose whether OmniWM warps across left/right or top/bottom monitor boundaries. " +
                        "The strip below is the \(warpAxis.orderDescription) order OmniWM uses for mouse warp."
                )
                    .font(.caption)
                    .foregroundColor(.secondary)

                MonitorOrderStrip(
                    entries: warpOrderEntries,
                    axis: warpAxis,
                    selectedMonitor: effectiveSelectedMonitorID,
                    onSelect: { selectedMonitor = $0 },
                    onMove: moveSelectedMonitor
                )

                if sortedMonitors.count <= 1 {
                    Text("Mouse warp ordering becomes relevant automatically when more than one monitor is connected.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Stepper(value: Binding(
                    get: { settings.mouseWarpMargin },
                    set: { settings.mouseWarpMargin = $0 }
                ), in: 1 ... 10) {
                    HStack {
                        Text("Warp Trigger Margin")
                        Spacer()
                        Text("\(settings.mouseWarpMargin) px")
                            .foregroundColor(.secondary)
                    }
                }

                Text(
                    "Horizontal mode uses left/right edges. Vertical mode uses top/bottom edges. " +
                        "Changing the axis keeps your saved monitor order as-is."
                )
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if warpAxis == .both {
                MouseWarpGridSettingsView(
                    settings: settings,
                    connectedMonitors: connectedMonitors
                )
            }
        }
        .onAppear(perform: refreshConnectedMonitors)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didChangeScreenParametersNotification
            )
        ) { _ in
            refreshConnectedMonitors()
        }
    }

    private func refreshConnectedMonitors() {
        let monitors = Monitor.current()
        connectedMonitors = monitors
        selectedMonitor = MonitorSettingsTabModel.normalizedSelection(
            selectedMonitor,
            entries: MonitorSettingsTabModel.orderEntries(
                for: MonitorSettingsTabModel.sortedMonitors(monitors, axis: warpAxis),
                orderedNames: settings.effectiveMouseWarpMonitorOrder(for: monitors, axis: warpAxis),
                axis: warpAxis
            )
        )
    }

    private func moveSelectedMonitor(_ direction: MonitorOrderMoveDirection) {
        guard let reordered = MonitorSettingsTabModel.reorderedNames(
            entries: warpOrderEntries,
            moving: effectiveSelectedMonitorID,
            direction: direction
        ) else {
            return
        }
        settings.mouseWarpMonitorOrder = reordered
    }
}

private struct MonitorOrderStrip: View {
    let entries: [MonitorOrderEntry]
    let axis: MouseWarpAxis
    let selectedMonitor: Monitor.ID?
    let onSelect: (Monitor.ID) -> Void
    let onMove: (MonitorOrderMoveDirection) -> Void

    var body: some View {
        if entries.isEmpty {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
                .overlay {
                    Text("No monitors detected")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 132)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: 14) {
                    ForEach(entries) { entry in
                        MonitorOrderSlot(
                            entry: entry,
                            axis: axis,
                            isSelected: selectedMonitor == entry.id,
                            showsMoveControls: entries.count > 1 && selectedMonitor == entry.id,
                            canMoveLeft: MonitorSettingsTabModel.canMove(
                                entries: entries,
                                moving: entry.id,
                                direction: .left
                            ),
                            canMoveRight: MonitorSettingsTabModel.canMove(
                                entries: entries,
                                moving: entry.id,
                                direction: .right
                            ),
                            onSelect: { onSelect(entry.id) },
                            onMoveLeft: { onMove(.left) },
                            onMoveRight: { onMove(.right) }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

private struct MonitorOrderSlot: View {
    let entry: MonitorOrderEntry
    let axis: MouseWarpAxis
    let isSelected: Bool
    let showsMoveControls: Bool
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let onSelect: () -> Void
    let onMoveLeft: () -> Void
    let onMoveRight: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if showsMoveControls {
                MonitorMoveButton(
                    symbolName: axis.leadingSymbolName,
                    isEnabled: canMoveLeft,
                    action: onMoveLeft
                )
            }

            Button(action: onSelect) {
                MonitorOrderCard(
                    entry: entry,
                    isSelected: isSelected
                )
            }
            .buttonStyle(.plain)

            if showsMoveControls {
                MonitorMoveButton(
                    symbolName: axis.trailingSymbolName,
                    isEnabled: canMoveRight,
                    action: onMoveRight
                )
            }
        }
    }
}

private struct MonitorMoveButton: View {
    let symbolName: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isEnabled ? .primary : .secondary.opacity(0.55))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct MonitorOrderCard: View {
    let entry: MonitorOrderEntry
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)

            Image(systemName: "display")
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(isSelected ? .accentColor : .secondary)

            Spacer(minLength: 0)

            Text(entry.displayLabel.name)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.75)

            MonitorBadgeRow(displayLabel: entry.displayLabel, isMain: entry.isMain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 150, height: 122)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.22), lineWidth: isSelected ? 2 : 1)
        )
    }
}

private struct MonitorBadgeRow: View {
    let displayLabel: MonitorDisplayLabel
    let isMain: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let duplicateBadge = displayLabel.badgeText {
                MonitorBadge(text: duplicateBadge)
            }

            if isMain {
                MonitorBadge(text: "Main")
            }
        }
    }
}

private struct MonitorBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }
}

private struct SelectedMonitorDetails: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let monitor: Monitor
    let displayLabel: MonitorDisplayLabel

    private var orientationOverride: Monitor.Orientation? {
        settings.orientationSettings(for: monitor)?.orientation
    }

    private var effectiveOrientation: Monitor.Orientation {
        settings.effectiveOrientation(for: monitor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(displayLabel.name)
                    .font(.title3.weight(.semibold))

                if let duplicateBadge = displayLabel.badgeText {
                    MonitorBadge(text: duplicateBadge)
                }

                if monitor.isMain {
                    MonitorBadge(text: "Main")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Auto-detected") {
                    Text(monitor.autoOrientation.displayName)
                        .foregroundColor(.secondary)
                }

                LabeledContent("Current") {
                    Text(effectiveOrientation.displayName)
                        .fontWeight(.medium)
                }
            }

            Picker("Orientation Override", selection: Binding(
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
                Button("Reset to Auto") {
                    updateOrientation(nil)
                }
                .buttonStyle(.borderless)
            }

            Text(
                "Override the auto-detected orientation for this monitor. " +
                "Vertical monitors scroll windows top-to-bottom instead of left-to-right."
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

struct MonitorDisplayLabel: Equatable {
    let name: String
    let duplicateIndex: Int?

    var badgeText: String? {
        duplicateIndex.map { "#\($0)" }
    }
}

struct MonitorOrderEntry: Identifiable, Equatable {
    let monitor: Monitor
    let displayLabel: MonitorDisplayLabel

    var id: Monitor.ID { monitor.id }
    var name: String { monitor.name }
    var isMain: Bool { monitor.isMain }
}

enum MonitorOrderMoveDirection {
    case left
    case right
}

enum MonitorSettingsTabModel {
    static func sortedMonitors(_ monitors: [Monitor], axis: MouseWarpAxis = .horizontal) -> [Monitor] {
        axis.sortedMonitors(monitors)
    }

    static func normalizedSelection(_ selectedMonitor: Monitor.ID?, entries: [MonitorOrderEntry]) -> Monitor.ID? {
        guard !entries.isEmpty else { return nil }

        if let selectedMonitor,
           entries.contains(where: { $0.id == selectedMonitor })
        {
            return selectedMonitor
        }

        return entries.first?.id
    }

    static func displayLabels(
        for monitors: [Monitor],
        axis: MouseWarpAxis = .horizontal
    ) -> [Monitor.ID: MonitorDisplayLabel] {
        let sorted = sortedMonitors(monitors, axis: axis)
        let totals = sorted.reduce(into: [String: Int]()) { counts, monitor in
            counts[monitor.name, default: 0] += 1
        }
        var nextIndexByName: [String: Int] = [:]
        var labels: [Monitor.ID: MonitorDisplayLabel] = [:]

        for monitor in sorted {
            nextIndexByName[monitor.name, default: 0] += 1
            let total = totals[monitor.name, default: 0]
            let duplicateIndex = total > 1 ? nextIndexByName[monitor.name] : nil
            labels[monitor.id] = MonitorDisplayLabel(name: monitor.name, duplicateIndex: duplicateIndex)
        }

        return labels
    }

    static func orderEntries(
        for monitors: [Monitor],
        orderedNames: [String],
        axis: MouseWarpAxis = .horizontal
    ) -> [MonitorOrderEntry] {
        let sorted = sortedMonitors(monitors, axis: axis)
        let labels = displayLabels(for: sorted, axis: axis)
        let monitorsByName = Dictionary(grouping: sorted, by: \.name)
        var usedCounts: [String: Int] = [:]
        var entries: [MonitorOrderEntry] = []

        for name in orderedNames {
            let usedCount = usedCounts[name, default: 0]
            guard let monitor = monitorsByName[name]?[usedCount],
                  let displayLabel = labels[monitor.id]
            else {
                continue
            }

            entries.append(MonitorOrderEntry(monitor: monitor, displayLabel: displayLabel))
            usedCounts[name] = usedCount + 1
        }

        return entries
    }

    static func canMove(
        entries: [MonitorOrderEntry],
        moving selectedMonitor: Monitor.ID?,
        direction: MonitorOrderMoveDirection
    ) -> Bool {
        guard let currentIndex = entries.firstIndex(where: { $0.id == selectedMonitor }) else {
            return false
        }

        switch direction {
        case .left:
            return currentIndex > 0
        case .right:
            return currentIndex < entries.count - 1
        }
    }

    static func reorderedNames(
        entries: [MonitorOrderEntry],
        moving selectedMonitor: Monitor.ID?,
        direction: MonitorOrderMoveDirection
    ) -> [String]? {
        guard let currentIndex = entries.firstIndex(where: { $0.id == selectedMonitor }) else {
            return nil
        }

        let targetIndex: Int
        switch direction {
        case .left:
            targetIndex = currentIndex - 1
        case .right:
            targetIndex = currentIndex + 1
        }

        guard entries.indices.contains(targetIndex) else { return nil }

        var reorderedEntries = entries
        reorderedEntries.swapAt(currentIndex, targetIndex)
        return reorderedEntries.map(\.name)
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
