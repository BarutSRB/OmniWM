// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Cocoa

@MainActor
enum QuakeFocusedWindowScreen {
    static func find(monitors: [Monitor], screens: [NSScreen]) -> NSScreen? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        if let displayId = Self.displayId(
            monitors: monitors,
            windowList: windowList,
            ownPID: ProcessInfo.processInfo.processIdentifier
        ) {
            return screens.first(where: { $0.displayId == displayId })
        }

        return nil
    }

    static func displayId(
        monitors: [Monitor],
        windowList: [[String: Any]],
        ownPID: pid_t,
        toAppKitRect: (CGRect) -> CGRect = ScreenCoordinateSpace.toAppKit(rect:)
    ) -> CGDirectDisplayID? {
        for windowInfo in windowList {
            guard let windowPID = int32Value(windowInfo[kCGWindowOwnerPID as String]),
                  windowPID != ownPID,
                  intValue(windowInfo[kCGWindowLayer as String]) == 0,
                  let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let x = cgFloatValue(boundsDict["X"]),
                  let y = cgFloatValue(boundsDict["Y"]),
                  let width = cgFloatValue(boundsDict["Width"]),
                  let height = cgFloatValue(boundsDict["Height"]),
                  x.isFinite,
                  y.isFinite,
                  width.isFinite,
                  height.isFinite,
                  width > 50,
                  height > 50,
                  width <= QuakeTerminalGeometryPolicy.maximumCustomFrameDimensionPoints,
                  height <= QuakeTerminalGeometryPolicy.maximumCustomFrameDimensionPoints
            else {
                continue
            }

            let appKitFrame = toAppKitRect(CGRect(x: x, y: y, width: width, height: height))
            if let monitor = appKitFrame.center.monitorApproximation(in: monitors) {
                return monitor.displayId
            }
        }

        return nil
    }

    private static func cgFloatValue(_ value: Any?) -> CGFloat? {
        switch value {
        case let value as CGFloat:
            return value
        case let value as Double:
            return CGFloat(value)
        case let value as Float:
            return CGFloat(value)
        case let value as Int:
            return CGFloat(value)
        case let value as NSNumber:
            return CGFloat(truncating: value)
        default:
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as Int32:
            return Int(value)
        case let value as Int64:
            return Int(exactly: value)
        case let value as NSNumber:
            guard let value = exactInt64Value(value) else { return nil }
            return Int(exactly: value)
        default:
            return nil
        }
    }

    private static func int32Value(_ value: Any?) -> Int32? {
        switch value {
        case let value as Int32:
            return value
        case let value as Int:
            return Int32(exactly: value)
        case let value as Int64:
            return Int32(exactly: value)
        case let value as NSNumber:
            guard let value = exactInt64Value(value) else { return nil }
            return Int32(exactly: value)
        default:
            return nil
        }
    }

    private static func exactInt64Value(_ value: NSNumber) -> Int64? {
        let type = CFNumberGetType(value)
        switch type {
        case .charType,
             .shortType,
             .intType,
             .longType,
             .longLongType,
             .sInt8Type,
             .sInt16Type,
             .sInt32Type,
             .sInt64Type,
             .cfIndexType,
             .nsIntegerType:
            var exact: Int64 = 0
            guard CFNumberGetValue(value, .sInt64Type, &exact) else { return nil }
            return exact
        default:
            var doubleValue = 0.0
            guard CFNumberGetValue(value, .doubleType, &doubleValue),
                  doubleValue.isFinite,
                  doubleValue.rounded(.towardZero) == doubleValue,
                  doubleValue >= Double(Int64.min),
                  doubleValue <= Double(Int64.max)
            else {
                return nil
            }
            let exact = Int64(doubleValue)
            guard Double(exact) == doubleValue else { return nil }
            return exact
        }
    }
}
