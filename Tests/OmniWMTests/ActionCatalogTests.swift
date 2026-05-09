import Testing

@testable import OmniWM

@Suite struct ActionCatalogTests {
    @Test func defaultBindingsMirrorActionCatalog() {
        let specs = ActionCatalog.allSpecs()
        let bindings = HotkeyBindingRegistry.defaults()

        #expect(bindings.map(\.id) == specs.map(\.id))
        #expect(bindings.count == specs.count)
    }

    @Test func searchMatchesKeywordsAndIpcMetadata() throws {
        let binding = try #require(
            HotkeyBindingRegistry.defaults().first { $0.id == "toggleWorkspaceBarVisibility" }
        )

        #expect(ActionCatalog.matchesSearch("workspace bar", binding: binding))
        #expect(ActionCatalog.matchesSearch("toggle-workspace-bar", binding: binding))
    }

    @Test func actionSpecCarriesPublicCommandDescriptor() throws {
        let spec = try #require(ActionCatalog.spec(for: "toggleWorkspaceBarVisibility"))

        #expect(spec.ipcCommandName == .toggleWorkspaceBar)
        #expect(spec.ipcDescriptor?.path == "command toggle-workspace-bar")
    }

    @Test func niriParameterizedResizeActionsUsePublicCommandDescriptors() throws {
        let spec = try #require(ActionCatalog.spec(for: "setColumnWidth.increase10Percent"))

        #expect(spec.ipcCommandName == .setColumnWidth)
        #expect(spec.ipcDescriptor?.path == "command set-column-width <size-change>")
    }

    @Test func niriWindowFocusActionsUsePublicCommandDescriptors() throws {
        let indexed = try #require(ActionCatalog.spec(for: "focusWindowInColumn.1"))
        let top = try #require(ActionCatalog.spec(for: "focusWindowTop"))
        let fallback = try #require(ActionCatalog.spec(for: "focusWindowOrWorkspaceDown"))

        #expect(indexed.ipcCommandName == .focusWindowInColumn)
        #expect(indexed.ipcDescriptor?.path == "command focus-window-in-column <number>")
        #expect(top.ipcCommandName == .focusWindowTop)
        #expect(top.ipcDescriptor?.path == "command focus-window top")
        #expect(fallback.ipcCommandName == .focusWindowOrWorkspaceDown)
        #expect(fallback.ipcDescriptor?.path == "command focus-window-or-workspace-down")
    }

    @Test func niriColumnMoveActionsUsePublicCommandDescriptors() throws {
        let first = try #require(ActionCatalog.spec(for: "moveColumnToFirst"))
        let indexed = try #require(ActionCatalog.spec(for: "moveColumnToIndex.1"))

        #expect(first.ipcCommandName == .moveColumnToFirst)
        #expect(first.ipcDescriptor?.path == "command move-column-to-first")
        #expect(indexed.ipcCommandName == .moveColumnToIndex)
        #expect(indexed.ipcDescriptor?.path == "command move-column-to-index <number>")
    }

    @Test func niriViewportActionsUsePublicCommandDescriptors() throws {
        let center = try #require(ActionCatalog.spec(for: "centerColumn"))
        let visible = try #require(ActionCatalog.spec(for: "centerVisibleColumns"))

        #expect(center.ipcCommandName == .centerColumn)
        #expect(center.ipcDescriptor?.path == "command center-column")
        #expect(visible.ipcCommandName == .centerVisibleColumns)
        #expect(visible.ipcDescriptor?.path == "command center-visible-columns")
    }

    @Test func niriWindowMoveActionsUsePublicCommandDescriptors() throws {
        let down = try #require(ActionCatalog.spec(for: "moveWindowDown"))
        let fallback = try #require(ActionCatalog.spec(for: "moveWindowDownOrToWorkspaceDown"))
        let consume = try #require(ActionCatalog.spec(for: "consumeWindowIntoColumn"))
        let expel = try #require(ActionCatalog.spec(for: "expelWindowFromColumn"))

        #expect(down.ipcCommandName == .moveWindowDown)
        #expect(down.ipcDescriptor?.path == "command move-window-down")
        #expect(fallback.ipcCommandName == .moveWindowDownOrToWorkspaceDown)
        #expect(fallback.ipcDescriptor?.path == "command move-window-down-or-to-workspace-down")
        #expect(consume.ipcCommandName == .consumeWindowIntoColumn)
        #expect(consume.ipcDescriptor?.path == "command consume-window-into-column")
        #expect(expel.ipcCommandName == .expelWindowFromColumn)
        #expect(expel.ipcDescriptor?.path == "command expel-window-from-column")
    }
}
