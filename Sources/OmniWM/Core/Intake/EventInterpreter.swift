import Foundation

@MainActor
final class EventInterpreter: EventIntakeSink {
    weak var controller: WMController?

    init(controller: WMController) {
        self.controller = controller
    }

    func handleIntakeEvent(_ stamped: StampedIntakeEvent) {
        guard let controller else { return }

        switch stamped.event {
        case let .cgs(event):
            controller.axEventHandler.handleCGSEvent(event)
        }
    }
}
