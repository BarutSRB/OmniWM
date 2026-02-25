import SwiftUI

struct MenuPaletteView: View {
    @ObservedObject var controller: MenuPaletteController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search menu items...", text: $controller.searchText)
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

            Divider()

            if controller.isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading menu items...")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if controller.filteredItems.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("No menu items found")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(controller.filteredItems) { item in
                                MenuPaletteRow(
                                    item: item,
                                    isSelected: item.id == controller.selectedItemId,
                                    showShortcut: controller.showShortcuts
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
                            if AppDelegate.sharedSettings?.animationsEnabled ?? true {
                                withAnimation(.easeInOut(duration: 0.1)) {
                                    proxy.scrollTo(id, anchor: .center)
                                }
                            } else {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 600, height: 400)
        .omniGlassEffect(in: RoundedRectangle(cornerRadius: 12))
    }
}

struct MenuPaletteRow: View {
    let item: MenuItemModel
    let isSelected: Bool
    let showShortcut: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                if !item.parentTitles.isEmpty {
                    Text(item.parentTitles.joined(separator: " > "))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if showShortcut, let shortcut = item.keyboardShortcut {
                Text(shortcut)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
    }
}
