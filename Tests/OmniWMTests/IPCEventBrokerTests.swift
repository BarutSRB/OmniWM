// SPDX-License-Identifier: GPL-2.0-only
import Testing

import OmniWMIPC
@testable import OmniWM

@Suite struct IPCEventBrokerTests {
    @Test func slowSubscribersKeepOnlyNewestBufferedEvent() async throws {
        let broker = IPCEventBroker()
        let stream = await broker.stream(for: .focus)

        await broker.publish(
            IPCEventEnvelope.success(
                id: "evt-1",
                channel: .focus,
                result: IPCResult(
                    focusedWindow: IPCFocusedWindowQueryResult(
                        window: IPCFocusedWindowSnapshot(
                            id: "ow_old",
                            workspace: IPCWorkspaceRef(id: "ws-1", rawName: "1", displayName: "One", number: 1),
                            display: IPCDisplayRef(id: "display:1", name: "Main", isMain: true),
                            app: IPCAppRef(name: "Old", bundleId: "com.example.old"),
                            title: "Old",
                            frame: nil
                        )
                    )
                )
            )
        )
        await broker.publish(
            IPCEventEnvelope.success(
                id: "evt-2",
                channel: .focus,
                result: IPCResult(
                    focusedWindow: IPCFocusedWindowQueryResult(
                        window: IPCFocusedWindowSnapshot(
                            id: "ow_new",
                            workspace: IPCWorkspaceRef(id: "ws-1", rawName: "1", displayName: "One", number: 1),
                            display: IPCDisplayRef(id: "display:1", name: "Main", isMain: true),
                            app: IPCAppRef(name: "New", bundleId: "com.example.new"),
                            title: "New",
                            frame: nil
                        )
                    )
                )
            )
        )

        var iterator = stream.makeAsyncIterator()
        let nextEvent = await iterator.next()
        let event = try #require(nextEvent)

        #expect(event.id == "evt-2")
        if case let .focusedWindow(payload) = event.result.payload {
            #expect(payload.window?.id == "ow_new")
            #expect(payload.window?.title == "New")
        } else {
            Issue.record("Expected focused-window payload")
        }
    }
}
