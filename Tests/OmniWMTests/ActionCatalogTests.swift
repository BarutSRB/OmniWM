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
}
