import IOKit
import IOKit.hidsystem

final class CapsLockToggler {
    private var hidConnection: io_connect_t = 0

    deinit {
        if hidConnection != 0 {
            IOServiceClose(hidConnection)
        }
    }

    @discardableResult
    func toggle() -> Bool {
        guard let connection = connection() else { return false }
        var isLocked = false
        guard IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &isLocked) == KERN_SUCCESS else {
            return false
        }
        return IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), !isLocked) == KERN_SUCCESS
    }

    private func connection() -> io_connect_t? {
        if hidConnection != 0 {
            return hidConnection
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var nextConnection: io_connect_t = 0
        guard IOServiceOpen(
            service,
            mach_task_self_,
            UInt32(kIOHIDParamConnectType),
            &nextConnection
        ) == KERN_SUCCESS else {
            return nil
        }

        hidConnection = nextConnection
        return nextConnection
    }
}
