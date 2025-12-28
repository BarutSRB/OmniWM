import CoreGraphics
import Foundation

enum SkyLightWindowOrder: Int32 {
    case above = 0
    case below = -1
}

@MainActor
final class SkyLight {
    static let shared = SkyLight()

    private typealias MainConnectionIDFunc = @convention(c) () -> Int32
    private typealias WindowQueryWindowsFunc = @convention(c) (Int32, CFArray, UInt32) -> CFTypeRef?
    private typealias WindowQueryResultCopyWindowsFunc = @convention(c) (CFTypeRef) -> CFTypeRef?
    private typealias WindowIteratorGetCountFunc = @convention(c) (CFTypeRef) -> Int32
    private typealias WindowIteratorAdvanceFunc = @convention(c) (CFTypeRef) -> Bool
    private typealias WindowIteratorGetCornerRadiiFunc = @convention(c) (CFTypeRef) -> CFArray?
    private typealias TransactionCreateFunc = @convention(c) (Int32) -> CFTypeRef?
    private typealias TransactionCommitFunc = @convention(c) (CFTypeRef, Int32) -> CGError
    private typealias TransactionOrderWindowFunc = @convention(c) (CFTypeRef, UInt32, Int32, UInt32) -> Void
    private typealias DisableUpdateFunc = @convention(c) (Int32) -> Void
    private typealias ReenableUpdateFunc = @convention(c) (Int32) -> Void
    private typealias MoveWindowFunc = @convention(c) (Int32, UInt32, UnsafePointer<CGPoint>) -> CGError
    private typealias GetWindowBoundsFunc = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> CGError

    private let mainConnectionID: MainConnectionIDFunc
    private let windowQueryWindows: WindowQueryWindowsFunc
    private let windowQueryResultCopyWindows: WindowQueryResultCopyWindowsFunc
    private let windowIteratorGetCount: WindowIteratorGetCountFunc
    private let windowIteratorAdvance: WindowIteratorAdvanceFunc
    private let windowIteratorGetCornerRadii: WindowIteratorGetCornerRadiiFunc
    private let transactionCreate: TransactionCreateFunc
    private let transactionCommit: TransactionCommitFunc
    private let transactionOrderWindow: TransactionOrderWindowFunc
    private let disableUpdate: DisableUpdateFunc
    private let reenableUpdate: ReenableUpdateFunc
    private let moveWindow: MoveWindowFunc?
    private let getWindowBounds: GetWindowBoundsFunc?

    private init() {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            fatalError("Failed to load SkyLight framework")
        }

        guard let mainConnectionID = unsafeBitCast(dlsym(lib, "SLSMainConnectionID"), to: MainConnectionIDFunc?.self),
              let windowQueryWindows = unsafeBitCast(
                  dlsym(lib, "SLSWindowQueryWindows"),
                  to: WindowQueryWindowsFunc?.self
              ),
              let windowQueryResultCopyWindows = unsafeBitCast(
                  dlsym(lib, "SLSWindowQueryResultCopyWindows"),
                  to: WindowQueryResultCopyWindowsFunc?.self
              ),
              let windowIteratorGetCount = unsafeBitCast(
                  dlsym(lib, "SLSWindowIteratorGetCount"),
                  to: WindowIteratorGetCountFunc?.self
              ),
              let windowIteratorAdvance = unsafeBitCast(
                  dlsym(lib, "SLSWindowIteratorAdvance"),
                  to: WindowIteratorAdvanceFunc?.self
              ),
              let windowIteratorGetCornerRadii = unsafeBitCast(
                  dlsym(lib, "SLSWindowIteratorGetCornerRadii"),
                  to: WindowIteratorGetCornerRadiiFunc?.self
              ),
              let transactionCreate = unsafeBitCast(
                  dlsym(lib, "SLSTransactionCreate"),
                  to: TransactionCreateFunc?.self
              ),
              let transactionCommit = unsafeBitCast(
                  dlsym(lib, "SLSTransactionCommit"),
                  to: TransactionCommitFunc?.self
              ),
              let transactionOrderWindow = unsafeBitCast(
                  dlsym(lib, "SLSTransactionOrderWindow"),
                  to: TransactionOrderWindowFunc?.self
              ),
              let disableUpdate = unsafeBitCast(dlsym(lib, "SLSDisableUpdate"), to: DisableUpdateFunc?.self),
              let reenableUpdate = unsafeBitCast(dlsym(lib, "SLSReenableUpdate"), to: ReenableUpdateFunc?.self)
        else {
            fatalError("Failed to load required SkyLight functions")
        }

        self.mainConnectionID = mainConnectionID
        self.windowQueryWindows = windowQueryWindows
        self.windowQueryResultCopyWindows = windowQueryResultCopyWindows
        self.windowIteratorGetCount = windowIteratorGetCount
        self.windowIteratorAdvance = windowIteratorAdvance
        self.windowIteratorGetCornerRadii = windowIteratorGetCornerRadii
        self.transactionCreate = transactionCreate
        self.transactionCommit = transactionCommit
        self.transactionOrderWindow = transactionOrderWindow
        self.disableUpdate = disableUpdate
        self.reenableUpdate = reenableUpdate

        self.moveWindow = unsafeBitCast(dlsym(lib, "SLSMoveWindow"), to: MoveWindowFunc?.self)
        self.getWindowBounds = unsafeBitCast(dlsym(lib, "SLSGetWindowBounds"), to: GetWindowBoundsFunc?.self)
    }

    func getMainConnectionID() -> Int32 {
        mainConnectionID()
    }

    func cornerRadius(forWindowId wid: Int) -> CGFloat? {
        let cid = getMainConnectionID()
        guard cid != 0 else { return nil }

        var widValue = Int32(wid)
        let widNumber = CFNumberCreate(nil, .sInt32Type, &widValue)!
        let windowArray = [widNumber] as CFArray

        guard let query = windowQueryWindows(cid, windowArray, 0),
              let iterator = windowQueryResultCopyWindows(query),
              windowIteratorGetCount(iterator) > 0,
              windowIteratorAdvance(iterator),
              let radii = windowIteratorGetCornerRadii(iterator),
              CFArrayGetCount(radii) > 0
        else {
            return nil
        }

        var radius: Int32 = 0
        let value = CFArrayGetValueAtIndex(radii, 0)
        guard CFNumberGetValue(unsafeBitCast(value, to: CFNumber.self), .sInt32Type, &radius) else {
            return nil
        }

        guard radius >= 0 else { return nil }
        return CGFloat(radius)
    }

    func disableUpdates() {
        let cid = getMainConnectionID()
        disableUpdate(cid)
    }

    func reenableUpdates() {
        let cid = getMainConnectionID()
        reenableUpdate(cid)
    }

    func orderWindow(_ wid: UInt32, relativeTo targetWid: UInt32, order: SkyLightWindowOrder = .above) {
        let cid = getMainConnectionID()
        guard let transaction = transactionCreate(cid) else {
            fatalError("Failed to create SkyLight transaction")
        }
        transactionOrderWindow(transaction, wid, order.rawValue, targetWid)
        _ = transactionCommit(transaction, 0)
    }

    func moveWindow(_ wid: UInt32, to point: CGPoint) -> Bool {
        guard let moveWindow else { return false }
        let cid = getMainConnectionID()
        guard cid != 0 else { return false }
        var pt = point
        let result = moveWindow(cid, wid, &pt)
        return result == .success
    }

    func getWindowBounds(_ wid: UInt32) -> CGRect? {
        guard let getWindowBounds else { return nil }
        let cid = getMainConnectionID()
        guard cid != 0 else { return nil }
        var rect = CGRect.zero
        let result = getWindowBounds(cid, wid, &rect)
        guard result == .success else { return nil }
        return rect
    }
}
