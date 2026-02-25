import CoreGraphics
import Foundation

enum SkyLightWindowOrder: Int32 {
    case above = 0
    case below = -1
}

private typealias CFReleaseFunc = @convention(c) (CFTypeRef) -> Void
private let cfRelease: CFReleaseFunc = {
    let lib = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_LAZY)!
    return unsafeBitCast(dlsym(lib, "CFRelease"), to: CFReleaseFunc.self)
}()

@MainActor
final class SkyLight {
    static let shared = SkyLight()

    private typealias MainConnectionIDFunc = @convention(c) () -> Int32
    private typealias WindowQueryWindowsFunc = @convention(c) (Int32, CFArray, UInt32) -> CFTypeRef?
    private typealias WindowQueryResultCopyWindowsFunc = @convention(c) (CFTypeRef) -> CFTypeRef?
    private typealias WindowIteratorGetCountFunc = @convention(c) (CFTypeRef) -> Int32
    private typealias WindowIteratorAdvanceFunc = @convention(c) (CFTypeRef) -> Bool
    private typealias WindowIteratorGetCornerRadiiFunc = @convention(c) (CFTypeRef) -> CFArray?
    private typealias WindowIteratorGetBoundsFunc = @convention(c) (CFTypeRef) -> CGRect
    private typealias WindowIteratorGetWindowIDFunc = @convention(c) (CFTypeRef) -> UInt32
    private typealias WindowIteratorGetPIDFunc = @convention(c) (CFTypeRef) -> Int32
    private typealias WindowIteratorGetLevelFunc = @convention(c) (CFTypeRef) -> Int32
    private typealias WindowIteratorGetTagsFunc = @convention(c) (CFTypeRef) -> UInt64
    private typealias WindowIteratorGetAttributesFunc = @convention(c) (CFTypeRef) -> UInt32
    private typealias WindowIteratorGetParentIDFunc = @convention(c) (CFTypeRef) -> UInt32
    private typealias TransactionCreateFunc = @convention(c) (Int32) -> CFTypeRef?
    private typealias TransactionCommitFunc = @convention(c) (CFTypeRef, Int32) -> CGError
    private typealias TransactionOrderWindowFunc = @convention(c) (CFTypeRef, UInt32, Int32, UInt32) -> Void
    private typealias TransactionMoveWindowWithGroupFunc = @convention(c) (CFTypeRef, UInt32, CGPoint) -> CGError
    private typealias DisableUpdateFunc = @convention(c) (Int32) -> Void
    private typealias ReenableUpdateFunc = @convention(c) (Int32) -> Void
    private typealias MoveWindowFunc = @convention(c) (Int32, UInt32, UnsafePointer<CGPoint>) -> CGError
    private typealias GetWindowBoundsFunc = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> CGError
    private typealias NewWindowFunc = @convention(c) (Int32, Int32, Float, Float, CFTypeRef, UnsafeMutablePointer<UInt32>) -> CGError
    private typealias ReleaseWindowFunc = @convention(c) (Int32, UInt32) -> CGError
    private typealias WindowContextCreateFunc = @convention(c) (Int32, UInt32, CFDictionary?) -> CGContext?
    private typealias SetWindowShapeFunc = @convention(c) (Int32, UInt32, Float, Float, CFTypeRef) -> CGError
    private typealias SetWindowResolutionFunc = @convention(c) (Int32, UInt32, Float) -> CGError
    private typealias SetWindowOpacityFunc = @convention(c) (Int32, UInt32, Int32) -> CGError
    private typealias SetWindowTagsFunc = @convention(c) (Int32, UInt32, UnsafePointer<UInt64>, Int32) -> CGError
    private typealias FlushWindowContentRegionFunc = @convention(c) (Int32, UInt32, CFTypeRef?) -> CGError
    private typealias NewRegionWithRectFunc = @convention(c) (UnsafePointer<CGRect>, UnsafeMutablePointer<CFTypeRef?>) -> CGError
    private typealias TransactionSetWindowLevelFunc = @convention(c) (CFTypeRef, UInt32, Int32) -> CGError

    typealias ConnectionNotifyCallback = @convention(c) (
        UInt32,
        UnsafeMutableRawPointer?,
        Int,
        UnsafeMutableRawPointer?,
        Int32
    ) -> Void
    private typealias RegisterConnectionNotifyProcFunc = @convention(c) (
        Int32,
        ConnectionNotifyCallback,
        UInt32,
        UnsafeMutableRawPointer?
    ) -> Int32
    private typealias UnregisterConnectionNotifyProcFunc = @convention(c) (
        Int32,
        ConnectionNotifyCallback,
        UInt32
    ) -> Int32
    private typealias RequestNotificationsForWindowsFunc = @convention(c) (
        Int32,
        UnsafePointer<UInt32>,
        Int32
    ) -> Int32

    typealias NotifyCallback = @convention(c) (
        UInt32,
        UnsafeMutableRawPointer?,
        Int,
        Int32
    ) -> Void
    private typealias RegisterNotifyProcFunc = @convention(c) (
        NotifyCallback,
        UInt32,
        UnsafeMutableRawPointer?
    ) -> Int32
    private typealias UnregisterNotifyProcFunc = @convention(c) (
        NotifyCallback,
        UInt32,
        UnsafeMutableRawPointer?
    ) -> Int32

    private let mainConnectionID: MainConnectionIDFunc
    private let windowQueryWindows: WindowQueryWindowsFunc
    private let windowQueryResultCopyWindows: WindowQueryResultCopyWindowsFunc
    private let windowIteratorGetCount: WindowIteratorGetCountFunc
    private let windowIteratorAdvance: WindowIteratorAdvanceFunc
    private let windowIteratorGetCornerRadii: WindowIteratorGetCornerRadiiFunc?
    private let windowIteratorGetBounds: WindowIteratorGetBoundsFunc?
    private let windowIteratorGetWindowID: WindowIteratorGetWindowIDFunc?
    private let windowIteratorGetPID: WindowIteratorGetPIDFunc?
    private let windowIteratorGetLevel: WindowIteratorGetLevelFunc?
    private let windowIteratorGetTags: WindowIteratorGetTagsFunc?
    private let windowIteratorGetAttributes: WindowIteratorGetAttributesFunc?
    private let windowIteratorGetParentID: WindowIteratorGetParentIDFunc?
    private let transactionCreate: TransactionCreateFunc
    private let transactionCommit: TransactionCommitFunc
    private let transactionOrderWindow: TransactionOrderWindowFunc
    private let transactionMoveWindowWithGroup: TransactionMoveWindowWithGroupFunc?
    private let disableUpdate: DisableUpdateFunc
    private let reenableUpdate: ReenableUpdateFunc
    private let moveWindow: MoveWindowFunc?
    private let getWindowBounds: GetWindowBoundsFunc?
    private let registerConnectionNotifyProc: RegisterConnectionNotifyProcFunc?
    private let unregisterConnectionNotifyProc: UnregisterConnectionNotifyProcFunc?
    private let requestNotificationsForWindows: RequestNotificationsForWindowsFunc?
    private let registerNotifyProc: RegisterNotifyProcFunc?
    private let unregisterNotifyProcFunc: UnregisterNotifyProcFunc?
    private let newWindow: NewWindowFunc?
    private let releaseWindow: ReleaseWindowFunc?
    private let windowContextCreate: WindowContextCreateFunc?
    private let setWindowShape: SetWindowShapeFunc?
    private let setWindowResolution: SetWindowResolutionFunc?
    private let setWindowOpacity: SetWindowOpacityFunc?
    private let setWindowTags: SetWindowTagsFunc?
    private let flushWindowContentRegion: FlushWindowContentRegionFunc?
    private let newRegionWithRect: NewRegionWithRectFunc?
    private let transactionSetWindowLevel: TransactionSetWindowLevelFunc?

    private init() {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            fatalError("Failed to load SkyLight framework")
        }

        func resolveOptional<T>(_ symbol: String, as _: T.Type) -> T? {
            guard let ptr = dlsym(lib, symbol) else { return nil }
            return unsafeBitCast(ptr, to: T.self)
        }

        var missingRequiredSymbols: [String] = []
        func resolveRequired<T>(_ symbol: String, as type: T.Type) -> T? {
            let resolved: T? = resolveOptional(symbol, as: type)
            if resolved == nil {
                missingRequiredSymbols.append(symbol)
            }
            return resolved
        }

        let mainConnectionID = resolveRequired("SLSMainConnectionID", as: MainConnectionIDFunc.self)
        let windowQueryWindows = resolveRequired("SLSWindowQueryWindows", as: WindowQueryWindowsFunc.self)
        let windowQueryResultCopyWindows = resolveRequired(
            "SLSWindowQueryResultCopyWindows",
            as: WindowQueryResultCopyWindowsFunc.self
        )
        let windowIteratorGetCount = resolveRequired("SLSWindowIteratorGetCount", as: WindowIteratorGetCountFunc.self)
        let windowIteratorAdvance = resolveRequired("SLSWindowIteratorAdvance", as: WindowIteratorAdvanceFunc.self)
        let transactionCreate = resolveRequired("SLSTransactionCreate", as: TransactionCreateFunc.self)
        let transactionCommit = resolveRequired("SLSTransactionCommit", as: TransactionCommitFunc.self)
        let transactionOrderWindow = resolveRequired("SLSTransactionOrderWindow", as: TransactionOrderWindowFunc.self)
        let disableUpdate = resolveRequired("SLSDisableUpdate", as: DisableUpdateFunc.self)
        let reenableUpdate = resolveRequired("SLSReenableUpdate", as: ReenableUpdateFunc.self)

        if !missingRequiredSymbols.isEmpty {
            let message = "SkyLight missing required symbols: \(missingRequiredSymbols.joined(separator: ", "))"
            if let data = "OmniWM: \(message)\n".data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
            fatalError(message)
        }

        guard let mainConnectionID,
              let windowQueryWindows,
              let windowQueryResultCopyWindows,
              let windowIteratorGetCount,
              let windowIteratorAdvance,
              let transactionCreate,
              let transactionCommit,
              let transactionOrderWindow,
              let disableUpdate,
              let reenableUpdate
        else {
            fatalError("SkyLight required symbol resolution failed")
        }

        self.mainConnectionID = mainConnectionID
        self.windowQueryWindows = windowQueryWindows
        self.windowQueryResultCopyWindows = windowQueryResultCopyWindows
        self.windowIteratorGetCount = windowIteratorGetCount
        self.windowIteratorAdvance = windowIteratorAdvance
        self.transactionCreate = transactionCreate
        self.transactionCommit = transactionCommit
        self.transactionOrderWindow = transactionOrderWindow
        self.disableUpdate = disableUpdate
        self.reenableUpdate = reenableUpdate

        windowIteratorGetCornerRadii = resolveOptional("SLSWindowIteratorGetCornerRadii", as: WindowIteratorGetCornerRadiiFunc.self)

        transactionMoveWindowWithGroup = resolveOptional("SLSTransactionMoveWindowWithGroup", as: TransactionMoveWindowWithGroupFunc.self)
        moveWindow = resolveOptional("SLSMoveWindow", as: MoveWindowFunc.self)
        getWindowBounds = resolveOptional("SLSGetWindowBounds", as: GetWindowBoundsFunc.self)

        windowIteratorGetBounds = resolveOptional("SLSWindowIteratorGetBounds", as: WindowIteratorGetBoundsFunc.self)
        windowIteratorGetWindowID = resolveOptional("SLSWindowIteratorGetWindowID", as: WindowIteratorGetWindowIDFunc.self)
        windowIteratorGetPID = resolveOptional("SLSWindowIteratorGetPID", as: WindowIteratorGetPIDFunc.self)
        windowIteratorGetLevel = resolveOptional("SLSWindowIteratorGetLevel", as: WindowIteratorGetLevelFunc.self)
        windowIteratorGetTags = resolveOptional("SLSWindowIteratorGetTags", as: WindowIteratorGetTagsFunc.self)
        windowIteratorGetAttributes = resolveOptional("SLSWindowIteratorGetAttributes", as: WindowIteratorGetAttributesFunc.self)
        windowIteratorGetParentID = resolveOptional("SLSWindowIteratorGetParentID", as: WindowIteratorGetParentIDFunc.self)

        registerConnectionNotifyProc = resolveOptional("SLSRegisterConnectionNotifyProc", as: RegisterConnectionNotifyProcFunc.self)
        unregisterConnectionNotifyProc = resolveOptional("SLSUnregisterConnectionNotifyProc", as: UnregisterConnectionNotifyProcFunc.self)
            ?? resolveOptional("SLSRemoveConnectionNotifyProc", as: UnregisterConnectionNotifyProcFunc.self)
        requestNotificationsForWindows = resolveOptional("SLSRequestNotificationsForWindows", as: RequestNotificationsForWindowsFunc.self)
        registerNotifyProc = resolveOptional("SLSRegisterNotifyProc", as: RegisterNotifyProcFunc.self)
        unregisterNotifyProcFunc = resolveOptional("SLSUnregisterNotifyProc", as: UnregisterNotifyProcFunc.self)
            ?? resolveOptional("SLSRemoveNotifyProc", as: UnregisterNotifyProcFunc.self)

        newWindow = resolveOptional("SLSNewWindow", as: NewWindowFunc.self)
        releaseWindow = resolveOptional("SLSReleaseWindow", as: ReleaseWindowFunc.self)
        windowContextCreate = resolveOptional("SLWindowContextCreate", as: WindowContextCreateFunc.self)
        setWindowShape = resolveOptional("SLSSetWindowShape", as: SetWindowShapeFunc.self)
        setWindowResolution = resolveOptional("SLSSetWindowResolution", as: SetWindowResolutionFunc.self)
        setWindowOpacity = resolveOptional("SLSSetWindowOpacity", as: SetWindowOpacityFunc.self)
        setWindowTags = resolveOptional("SLSSetWindowTags", as: SetWindowTagsFunc.self)
        flushWindowContentRegion = resolveOptional("SLSFlushWindowContentRegion", as: FlushWindowContentRegionFunc.self)
        newRegionWithRect = resolveOptional("CGSNewRegionWithRect", as: NewRegionWithRectFunc.self)
        transactionSetWindowLevel = resolveOptional("SLSTransactionSetWindowLevel", as: TransactionSetWindowLevelFunc.self)
    }

    func getMainConnectionID() -> Int32 {
        mainConnectionID()
    }

    func cornerRadius(forWindowId wid: Int) -> CGFloat? {
        guard let windowIteratorGetCornerRadii else { return nil }
        let cid = getMainConnectionID()
        guard cid != 0 else { return nil }

        var widValue = Int32(wid)
        let widNumber = CFNumberCreate(nil, .sInt32Type, &widValue)!
        defer { cfRelease(widNumber) }
        let windowArray = [widNumber] as CFArray

        guard let query = windowQueryWindows(cid, windowArray, 0) else { return nil }
        defer { cfRelease(query) }
        guard let iterator = windowQueryResultCopyWindows(query) else { return nil }
        defer { cfRelease(iterator) }

        guard windowIteratorGetCount(iterator) > 0,
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

    func orderWindow(_ wid: UInt32, relativeTo targetWid: UInt32, order: SkyLightWindowOrder = .above) {
        let cid = getMainConnectionID()
        guard let transaction = transactionCreate(cid) else {
            fatalError("Failed to create SkyLight transaction")
        }
        defer { cfRelease(transaction) }
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

    func batchMoveWindows(_ positions: [(windowId: UInt32, origin: CGPoint)]) {
        guard let transactionMoveWindowWithGroup else {
            for (windowId, origin) in positions {
                _ = moveWindow(windowId, to: origin)
            }
            return
        }

        let cid = getMainConnectionID()
        guard let transaction = transactionCreate(cid) else {
            for (windowId, origin) in positions {
                _ = moveWindow(windowId, to: origin)
            }
            return
        }
        defer { cfRelease(transaction) }

        for (windowId, origin) in positions {
            _ = transactionMoveWindowWithGroup(transaction, windowId, origin)
        }

        _ = transactionCommit(transaction, 0)
    }

    func queryAllVisibleWindows() -> [WindowServerInfo] {
        guard let windowIteratorGetBounds,
              let windowIteratorGetWindowID,
              let windowIteratorGetPID,
              let windowIteratorGetLevel,
              let windowIteratorGetTags,
              let windowIteratorGetAttributes,
              let windowIteratorGetParentID
        else { return [] }

        let cid = getMainConnectionID()
        guard cid != 0 else { return [] }

        let emptyArray = [] as CFArray
        guard let query = windowQueryWindows(cid, emptyArray, 0) else { return [] }
        defer { cfRelease(query) }
        guard let iterator = windowQueryResultCopyWindows(query) else { return [] }
        defer { cfRelease(iterator) }

        var results: [WindowServerInfo] = []

        while windowIteratorAdvance(iterator) {
            let parentId = windowIteratorGetParentID(iterator)
            guard parentId == 0 else { continue }

            let level = windowIteratorGetLevel(iterator)
            guard level == 0 || level == 3 || level == 8 else { continue }

            let tags = windowIteratorGetTags(iterator)
            let attributes = windowIteratorGetAttributes(iterator)

            let hasVisibleAttribute = (attributes & 0x2) != 0
            let hasTagBit54 = (tags & 0x0040_0000_0000_0000) != 0
            guard hasVisibleAttribute || hasTagBit54 else { continue }

            let isDocument = (tags & 0x1) != 0
            let isFloating = (tags & 0x2) != 0
            let isModal = (tags & 0x8000_0000) != 0
            guard isDocument || (isFloating && isModal) else { continue }

            let wid = windowIteratorGetWindowID(iterator)
            let pid = windowIteratorGetPID(iterator)
            let bounds = windowIteratorGetBounds(iterator)

            results.append(WindowServerInfo(
                id: wid,
                pid: pid,
                level: level,
                frame: bounds,
                tags: tags,
                attributes: attributes,
                parentId: parentId
            ))
        }

        return results
    }

    func queryWindowInfo(_ windowId: UInt32) -> WindowServerInfo? {
        guard let windowIteratorGetBounds,
              let windowIteratorGetWindowID,
              let windowIteratorGetPID,
              let windowIteratorGetLevel,
              let windowIteratorGetTags,
              let windowIteratorGetAttributes,
              let windowIteratorGetParentID
        else { return nil }

        let cid = getMainConnectionID()
        guard cid != 0 else { return nil }

        var widValue = Int32(windowId)
        let widNumber = CFNumberCreate(nil, .sInt32Type, &widValue)!
        defer { cfRelease(widNumber) }
        let windowArray = [widNumber] as CFArray

        guard let query = windowQueryWindows(cid, windowArray, 1) else { return nil }
        defer { cfRelease(query) }
        guard let iterator = windowQueryResultCopyWindows(query) else { return nil }
        defer { cfRelease(iterator) }
        guard windowIteratorAdvance(iterator) else { return nil }

        let wid = windowIteratorGetWindowID(iterator)
        let pid = windowIteratorGetPID(iterator)
        let level = windowIteratorGetLevel(iterator)
        let bounds = windowIteratorGetBounds(iterator)
        let tags = windowIteratorGetTags(iterator)
        let attributes = windowIteratorGetAttributes(iterator)
        let parentId = windowIteratorGetParentID(iterator)

        return WindowServerInfo(
            id: wid,
            pid: pid,
            level: level,
            frame: bounds,
            tags: tags,
            attributes: attributes,
            parentId: parentId
        )
    }

    func registerForNotification(
        event: CGSEventType,
        callback: @escaping ConnectionNotifyCallback,
        context: UnsafeMutableRawPointer? = nil
    ) -> Bool {
        guard let registerConnectionNotifyProc else {
            return false
        }
        let cid = getMainConnectionID()
        guard cid != 0 else {
            return false
        }
        let result = registerConnectionNotifyProc(cid, callback, event.rawValue, context)
        return result == 0
    }

    func unregisterForNotification(
        event: CGSEventType,
        callback: @escaping ConnectionNotifyCallback
    ) -> Bool {
        guard let unregisterConnectionNotifyProc else {
            return false
        }
        let cid = getMainConnectionID()
        guard cid != 0 else { return false }
        let result = unregisterConnectionNotifyProc(cid, callback, event.rawValue)
        return result == 0
    }

    func registerNotifyProc(
        event: CGSEventType,
        callback: @escaping NotifyCallback,
        context: UnsafeMutableRawPointer? = nil
    ) -> Bool {
        guard let registerNotifyProc else {
            return false
        }
        let result = registerNotifyProc(callback, event.rawValue, context)
        return result == 0
    }

    func unregisterNotifyProc(
        event: CGSEventType,
        callback: @escaping NotifyCallback,
        context: UnsafeMutableRawPointer? = nil
    ) -> Bool {
        guard let unregisterNotifyProcFunc else {
            return false
        }
        let result = unregisterNotifyProcFunc(callback, event.rawValue, context)
        return result == 0
    }

    func subscribeToWindowNotifications(_ windowIds: [UInt32]) -> Bool {
        guard let requestNotificationsForWindows else {
            return false
        }
        guard !windowIds.isEmpty else {
            return true
        }
        let cid = getMainConnectionID()
        guard cid != 0 else {
            return false
        }
        let result = windowIds.withUnsafeBufferPointer { buffer in
            requestNotificationsForWindows(cid, buffer.baseAddress!, Int32(windowIds.count))
        }
        return result == 0
    }

    func getWindowTitle(_ windowId: UInt32) -> String? {
        let options: CGWindowListOption = [.optionIncludingWindow]
        guard let windowList = CGWindowListCopyWindowInfo(options, CGWindowID(windowId)) as? [[String: Any]],
              let windowInfo = windowList.first,
              let title = windowInfo[kCGWindowName as String] as? String
        else { return nil }
        return title
    }

    func createBorderWindow(frame: CGRect) -> UInt32 {
        guard let newWindow, let newRegionWithRect else { return 0 }
        let cid = getMainConnectionID()
        guard cid != 0 else { return 0 }

        var region: CFTypeRef?
        var rect = frame
        _ = newRegionWithRect(&rect, &region)
        guard let region else { return 0 }

        var wid: UInt32 = 0
        _ = newWindow(cid, 2, -9999, -9999, region, &wid)
        return wid
    }

    func releaseBorderWindow(_ wid: UInt32) {
        guard let releaseWindow else { return }
        let cid = getMainConnectionID()
        guard cid != 0 else { return }
        _ = releaseWindow(cid, wid)
    }

    func createWindowContext(for wid: UInt32) -> CGContext? {
        guard let windowContextCreate else { return nil }
        let cid = getMainConnectionID()
        guard cid != 0 else { return nil }
        return windowContextCreate(cid, wid, nil)
    }

    func setWindowShape(_ wid: UInt32, frame: CGRect) {
        guard let setWindowShape, let newRegionWithRect else { return }
        let cid = getMainConnectionID()
        guard cid != 0 else { return }

        var region: CFTypeRef?
        var rect = frame
        _ = newRegionWithRect(&rect, &region)
        guard let region else { return }

        disableUpdate(cid)
        _ = setWindowShape(cid, wid, -9999, -9999, region)
        reenableUpdate(cid)
    }

    func configureWindow(_ wid: UInt32, resolution: Float, opaque: Bool) {
        let cid = getMainConnectionID()
        guard cid != 0 else { return }
        _ = setWindowResolution?(cid, wid, resolution)
        _ = setWindowOpacity?(cid, wid, opaque ? 1 : 0)
    }


    func setWindowTags(_ wid: UInt32, tags: UInt64) {
        guard let setWindowTags else { return }
        let cid = getMainConnectionID()
        guard cid != 0 else { return }
        var t = tags
        _ = setWindowTags(cid, wid, &t, 64)
    }

    func flushWindow(_ wid: UInt32) {
        guard let flushWindowContentRegion else { return }
        let cid = getMainConnectionID()
        guard cid != 0 else { return }
        _ = flushWindowContentRegion(cid, wid, nil)
    }

    func transactionMoveAndOrder(_ wid: UInt32, origin: CGPoint, level: Int32, relativeTo targetWid: UInt32, order: SkyLightWindowOrder) {
        let cid = getMainConnectionID()
        guard let transaction = transactionCreate(cid) else { return }
        defer { cfRelease(transaction) }

        if let transactionMoveWindowWithGroup {
            _ = transactionMoveWindowWithGroup(transaction, wid, origin)
        }
        if let transactionSetWindowLevel {
            _ = transactionSetWindowLevel(transaction, wid, level)
        }
        transactionOrderWindow(transaction, wid, order.rawValue, targetWid)
        _ = transactionCommit(transaction, 0)
    }

    func transactionHide(_ wid: UInt32) {
        let cid = getMainConnectionID()
        guard let transaction = transactionCreate(cid) else { return }
        defer { cfRelease(transaction) }
        transactionOrderWindow(transaction, wid, 0, 0)
        _ = transactionCommit(transaction, 0)
    }
}

enum CGSEventType: UInt32 {
    case windowClosed = 804
    case windowMoved = 806
    case windowResized = 807
    case windowTitleChanged = 1322
    case spaceWindowCreated = 1325
    case spaceWindowDestroyed = 1326
    case frontmostApplicationChanged = 1508
    case all = 0xFFFF_FFFF
}

struct WindowServerInfo {
    let id: UInt32
    let pid: Int32
    let level: Int32
    let frame: CGRect
    var tags: UInt64 = 0
    var attributes: UInt32 = 0
    var parentId: UInt32 = 0
    var title: String?
}
