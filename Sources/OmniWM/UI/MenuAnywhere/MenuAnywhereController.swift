@preconcurrency import AppKit
@preconcurrency import ApplicationServices

@MainActor
final class MenuAnywhereController: NSObject, NSMenuDelegate {
    static let shared = MenuAnywhereController()

    private let menuExtractor = MenuExtractor()
    private weak var currentApp: NSRunningApplication?
    private var activeMenu: NSMenu?
    private let axFetchQueue = DispatchQueue(label: "com.omniwm.menufetch", qos: .userInitiated)

    private static let kAXPressAction = "AXPress" as CFString
    private static let appActivationDelay: TimeInterval = 0.1

    private override init() {
        super.init()
    }

    func showNativeMenu(at position: MenuAnywherePosition) {
        cleanupActiveMenu()

        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        currentApp = app

        guard let menuBar = menuExtractor.getMenuBar(for: app.processIdentifier) else { return }

        let items = menuExtractor.buildMenu(
            from: menuBar,
            target: self,
            action: #selector(menuAction(_:))
        )

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.axRootElement = menuBar
        items.forEach(menu.addItem)
        activeMenu = menu

        let location = menuLocation(for: position)
        menu.popUp(positioning: nil, at: location, in: nil)
    }

    private func menuLocation(for position: MenuAnywherePosition) -> NSPoint {
        switch position {
        case .cursor:
            return NSEvent.mouseLocation
        case .centered:
            guard let screen = NSScreen.main else { return NSEvent.mouseLocation }
            return NSPoint(
                x: screen.frame.midX,
                y: screen.frame.midY
            )
        case .menuBarLocation:
            guard let screen = NSScreen.main else { return NSEvent.mouseLocation }
            return NSPoint(
                x: screen.frame.origin.x + 100,
                y: screen.frame.maxY - 22
            )
        }
    }

    private func cleanupActiveMenu() {
        guard let menu = activeMenu else { return }

        cleanupMenuItems(menu.items)
        menu.removeAllItems()
        activeMenu = nil
    }

    private func cleanupMenuItems(_ items: [NSMenuItem]) {
        for item in items {
            if let submenu = item.submenu {
                cleanupMenuItems(submenu.items)
                submenu.removeAllItems()
            }
            item.representedObject = nil
            item.target = nil
            item.action = nil
        }
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let obj = sender.representedObject,
              CFGetTypeID(obj as CFTypeRef) == AXUIElementGetTypeID(),
              let app = currentApp, !app.isTerminated
        else { return }

        let element = obj as! AXUIElement

        if !app.isActive {
            app.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.appActivationDelay) {
                AXUIElementPerformAction(element, Self.kAXPressAction)
            }
        } else {
            AXUIElementPerformAction(element, Self.kAXPressAction)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === activeMenu {
            DispatchQueue.main.async { [weak self] in
                self?.cleanupActiveMenu()
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === activeMenu { return }

        guard menu.items.isEmpty, let axRoot = menu.axRootElement else { return }
        guard menu.isPopulatingAsynchronously == false else { return }

        menu.isPopulatingAsynchronously = true

        let placeholder = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
        placeholder.isEnabled = false
        menu.addItem(placeholder)
        populateSubmenuAsync(menu: menu, axRoot: axRoot)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === activeMenu { return }
        guard menu.items.isEmpty, let axRoot = menu.axRootElement else { return }
        let items = menuExtractor.buildSubmenu(
            from: axRoot, target: self, action: #selector(menuAction(_:))
        )
        menu.removeAllItems()
        items.forEach(menu.addItem)
    }

    private func populateSubmenuAsync(menu: NSMenu, axRoot: AXUIElement) {
        nonisolated(unsafe) let menu = menu
        let extractor = self.menuExtractor
        axFetchQueue.async { [weak self] in
            guard let children = axRoot.getChildren() else {
                DispatchQueue.main.async {
                    menu.removeAllItems()
                    let empty = NSMenuItem(title: "(No items)", action: nil, keyEquivalent: "")
                    empty.isEnabled = false
                    menu.addItem(empty)
                    menu.isPopulatingAsynchronously = false
                }
                return
            }

            let attrs = [
                "AXTitle", "AXRole", "AXRoleDescription", "AXEnabled",
                "AXMenuItemMarkChar", "AXMenuItemCmdChar", "AXMenuItemCmdModifiers", "AXChildren",
            ]
            var itemsData: [[String: Any]] = []
            itemsData.reserveCapacity(children.count)
            for child in children {
                if let values = child.getMultipleAttributes(attrs) {
                    itemsData.append(values)
                } else {
                    itemsData.append([:])
                }
            }

            DispatchQueue.main.async {
                guard let self = self else { return }
                let submenuItems = extractor.buildSubmenu(
                    fromChildren: children, itemsData: itemsData, target: self,
                    action: #selector(self.menuAction(_:))
                )
                menu.removeAllItems()
                for item in submenuItems {
                    menu.addItem(item)
                }
                if submenuItems.isEmpty {
                    let empty = NSMenuItem(title: "(No items)", action: nil, keyEquivalent: "")
                    empty.isEnabled = false
                    menu.addItem(empty)
                }
                menu.isPopulatingAsynchronously = false
            }
        }
    }
}
