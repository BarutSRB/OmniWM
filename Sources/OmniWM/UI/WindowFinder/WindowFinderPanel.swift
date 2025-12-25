import AppKit
import SwiftUI

struct WindowFinderItem: Identifiable {
    let id: UUID
    let handle: WindowHandle
    let title: String
    let appName: String
    let appIcon: NSImage?
    let workspaceName: String
    let workspaceId: WorkspaceDescriptor.ID
}

@MainActor
final class WindowFinderController: ObservableObject {
    static let shared = WindowFinderController()

    @Published var isVisible = false
    @Published var searchText = "" {
        didSet {
            updateSelectionAfterFilterChange()
        }
    }

    @Published var selectedItemId: UUID?
    @Published var windows: [WindowFinderItem] = [] {
        didSet { updateSelectionAfterFilterChange() }
    }

    var filteredWindows: [WindowFinderItem] {
        filterWindows(windows, query: searchText)
    }

    private var panel: NSPanel?
    private var onSelect: ((WindowFinderItem) -> Void)?
    private var eventMonitor: Any?

    private init() {}

    private func filterWindows(_ items: [WindowFinderItem], query rawQuery: String) -> [WindowFinderItem] {
        let trimmedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            return items
        }
        let query = trimmedQuery.lowercased()

        let scored: [(WindowFinderItem, Int)] = items.compactMap { item in
            let titleLower = item.title.lowercased()
            let appLower = item.appName.lowercased()

            if let range = titleLower.range(of: query) {
                let pos = titleLower.distance(from: titleLower.startIndex, to: range.lowerBound)
                return (item, pos)
            }

            if let range = appLower.range(of: query) {
                let pos = appLower.distance(from: appLower.startIndex, to: range.lowerBound)
                return (item, 1000 + pos)
            }

            return nil
        }

        return scored
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                if a.0.title.count != b.0.title.count { return a.0.title.count < b.0.title.count }
                return a.0.title < b.0.title
            }
            .map(\.0)
    }

    func show(windows: [WindowFinderItem], onSelect: @escaping (WindowFinderItem) -> Void) {
        self.windows = windows
        self.onSelect = onSelect
        searchText = ""
        selectedItemId = windows.first?.id

        if panel == nil {
            createPanel()
        }

        guard let panel else { return }

        if let screen = NSScreen.main {
            let panelWidth: CGFloat = 500
            let panelHeight: CGFloat = 400
            let x = (screen.frame.width - panelWidth) / 2 + screen.frame.origin.x
            let y = (screen.frame.height - panelHeight) / 2 + screen.frame.origin.y + 100
            panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, isVisible else { return event }

            switch event.keyCode {
            case 53:
                hide()
                return nil
            case 126:
                moveSelection(by: -1)
                return nil
            case 125:
                moveSelection(by: 1)
                return nil
            case 36:
                selectCurrent()
                return nil
            default:
                return event
            }
        }

        isVisible = true
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async { [weak self] in
            self?.focusSearchField()
        }
    }

    func hide() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }

        isVisible = false
        panel?.orderOut(nil)
        searchText = ""
        selectedItemId = nil
    }

    func selectCurrent() {
        let filtered = filteredWindows
        guard let id = selectedItemId,
              let item = filtered.first(where: { $0.id == id }) else { return }
        hide()
        onSelect?(item)
    }

    func moveSelection(by delta: Int) {
        let filtered = filteredWindows
        guard !filtered.isEmpty else { return }

        let currentIndex: Int = if let id = selectedItemId,
                                   let idx = filtered.firstIndex(where: { $0.id == id })
        {
            idx
        } else {
            0
        }

        let newIndex = (currentIndex + delta + filtered.count) % filtered.count
        selectedItemId = filtered[newIndex].id
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false

        let hostingView = NSHostingView(rootView: WindowFinderView(controller: self))
        panel.contentView = hostingView

        self.panel = panel
    }

    private func findTextField(in view: NSView) -> NSTextField? {
        if let textField = view as? NSTextField, textField.isEditable {
            return textField
        }
        for subview in view.subviews {
            if let found = findTextField(in: subview) {
                return found
            }
        }
        return nil
    }

    func focusSearchField() {
        guard let contentView = panel?.contentView,
              let textField = findTextField(in: contentView) else { return }
        panel?.makeFirstResponder(textField)
    }

    private func updateSelectionAfterFilterChange() {
        let filtered = filteredWindows
        if filtered.isEmpty {
            selectedItemId = nil
            return
        }

        if let id = selectedItemId, !filtered.contains(where: { $0.id == id }) {
            selectedItemId = filtered.first?.id
        } else if selectedItemId == nil {
            selectedItemId = filtered.first?.id
        }
    }
}

struct WindowFinderView: View {
    @ObservedObject var controller: WindowFinderController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search windows...", text: $controller.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .onSubmit {
                        controller.selectCurrent()
                    }
                if !controller.searchText.isEmpty {
                    Button(action: { controller.searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(controller.filteredWindows) { item in
                            WindowFinderRow(
                                item: item,
                                isSelected: item.id == controller.selectedItemId
                            )
                            .id(item.id)
                            .onTapGesture {
                                controller.selectedItemId = item.id
                                controller.selectCurrent()
                            }
                        }
                    }
                }
                .onChange(of: controller.selectedItemId) { _, newId in
                    if let id = newId {
                        withAnimation(.easeInOut(duration: 0.1)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: 500, height: 400)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
    }
}

struct WindowFinderRow: View {
    let item: WindowFinderItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let icon = item.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .frame(width: 32, height: 32)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? item.appName : item.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text(item.appName)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(item.workspaceName)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.2))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
    }
}
