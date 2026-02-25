import Foundation

enum CGSWindowEvent {
    case created(windowId: UInt32, spaceId: UInt64)
    case destroyed(windowId: UInt32, spaceId: UInt64)
    case moved(windowId: UInt32)
    case resized(windowId: UInt32)
    case closed(windowId: UInt32)
    case frontAppChanged(pid: pid_t)
    case titleChanged(windowId: UInt32)
}

@MainActor
protocol CGSEventDelegate: AnyObject {
    func cgsEventObserver(_ observer: CGSEventObserver, didReceive event: CGSWindowEvent)
}

@MainActor
final class CGSEventObserver {
    static let shared = CGSEventObserver()

    weak var delegate: CGSEventDelegate?

    private var isRegistered = false
    private var isWindowClosedNotifyRegistered = false

    private init() {}

    func start() {
        guard !isRegistered else { return }

        let eventsViaConnectionNotify: [CGSEventType] = [
            .spaceWindowCreated,
            .spaceWindowDestroyed,
            .windowMoved,
            .windowResized,
            .windowTitleChanged,
            .frontmostApplicationChanged
        ]

        var successCount = 0
        for event in eventsViaConnectionNotify {
            let success = SkyLight.shared.registerForNotification(
                event: event,
                callback: cgsConnectionCallback,
                context: nil
            )
            if success {
                successCount += 1
            }
        }

        if isWindowClosedNotifyRegistered {
            successCount += 1
        } else {
            let cid = SkyLight.shared.getMainConnectionID()
            let cidContext = UnsafeMutableRawPointer(bitPattern: Int(cid))
            let windowClosedSuccess = SkyLight.shared.registerNotifyProc(
                event: .windowClosed,
                callback: notifyCallback,
                context: cidContext
            )
            if windowClosedSuccess {
                successCount += 1
                isWindowClosedNotifyRegistered = true
            }
        }

        isRegistered = successCount > 0
    }

    func stop() {
        if isRegistered {
            let eventsToUnregister: [CGSEventType] = [
                .spaceWindowCreated,
                .spaceWindowDestroyed,
                .windowMoved,
                .windowResized,
                .windowTitleChanged,
                .frontmostApplicationChanged
            ]

            for event in eventsToUnregister {
                _ = SkyLight.shared.unregisterForNotification(
                    event: event,
                    callback: cgsConnectionCallback
                )
            }

            isRegistered = false
        }

        if isWindowClosedNotifyRegistered {
            let cid = SkyLight.shared.getMainConnectionID()
            let cidContext = UnsafeMutableRawPointer(bitPattern: Int(cid))
            if SkyLight.shared.unregisterNotifyProc(
                event: .windowClosed,
                callback: notifyCallback,
                context: cidContext
            ) {
                isWindowClosedNotifyRegistered = false
            }
        }
    }

    @discardableResult
    func subscribeToWindows(_ windowIds: [UInt32]) -> Bool {
        SkyLight.shared.subscribeToWindowNotifications(windowIds)
    }

    fileprivate func handleEventFromCopy(_ eventType: UInt32, data: [UInt8]?) {
        guard isRegistered else {
            return
        }
        guard let cgsEvent = CGSEventType(rawValue: eventType) else {
            return
        }

        switch cgsEvent {
        case .spaceWindowCreated:
            guard let data, data.count >= 12 else { return }
            let spaceId = data.withUnsafeBytes { $0.load(as: UInt64.self) }
            let windowId = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
            delegate?.cgsEventObserver(self, didReceive: .created(windowId: windowId, spaceId: spaceId))

        case .spaceWindowDestroyed:
            guard let data, data.count >= 12 else { return }
            let spaceId = data.withUnsafeBytes { $0.load(as: UInt64.self) }
            let windowId = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
            delegate?.cgsEventObserver(self, didReceive: .destroyed(windowId: windowId, spaceId: spaceId))

        case .windowClosed:
            guard let data, data.count >= 4 else { return }
            let windowId = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            delegate?.cgsEventObserver(self, didReceive: .closed(windowId: windowId))

        case .windowMoved:
            guard let data, data.count >= 4 else { return }
            let windowId = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            delegate?.cgsEventObserver(self, didReceive: .moved(windowId: windowId))

        case .windowResized:
            guard let data, data.count >= 4 else { return }
            let windowId = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            delegate?.cgsEventObserver(self, didReceive: .resized(windowId: windowId))

        case .frontmostApplicationChanged:
            guard let data, data.count >= 4 else { return }
            let pid = data.withUnsafeBytes { $0.load(as: Int32.self) }
            delegate?.cgsEventObserver(self, didReceive: .frontAppChanged(pid: pid))

        case .windowTitleChanged:
            guard let data, data.count >= 4 else { return }
            let windowId = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            delegate?.cgsEventObserver(self, didReceive: .titleChanged(windowId: windowId))

        default:
            break
        }
    }
}

private func cgsConnectionCallback(
    event: UInt32,
    data: UnsafeMutableRawPointer?,
    length: Int,
    context _: UnsafeMutableRawPointer?,
    cid _: Int32
) {
    var dataCopy: [UInt8]?
    if let data, length > 0 {
        dataCopy = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: length))
    }

    DispatchQueue.main.async {
        CGSEventObserver.shared.handleEventFromCopy(event, data: dataCopy)
    }
}

private func notifyCallback(
    event: UInt32,
    data: UnsafeMutableRawPointer?,
    length: Int,
    cid _: Int32
) {
    var dataCopy: [UInt8]?
    if let data, length > 0 {
        dataCopy = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: length))
    }

    DispatchQueue.main.async {
        CGSEventObserver.shared.handleEventFromCopy(event, data: dataCopy)
    }
}
