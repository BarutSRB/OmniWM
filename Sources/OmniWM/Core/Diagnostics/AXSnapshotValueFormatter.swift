// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation

enum AXSnapshotValueFormatter {
    static func describe(_ value: CFTypeRef, arrayLimit: Int) -> String {
        let typeId = CFGetTypeID(value)
        if typeId == CFStringGetTypeID() {
            return bounded(value as? String ?? "")
        }
        if typeId == CFBooleanGetTypeID(), let value = value as? Bool {
            return value ? "true" : "false"
        }
        if typeId == CFNumberGetTypeID(), let value = value as? NSNumber {
            return value.stringValue
        }
        if typeId == AXValueGetTypeID() {
            return describeAXValue(unsafeDowncast(value, to: AXValue.self))
        }
        if typeId == AXUIElementGetTypeID() {
            return describeElement(unsafeDowncast(value, to: AXUIElement.self))
        }
        if typeId == CFArrayGetTypeID() {
            let values = (value as? [AnyObject]) ?? []
            var descriptions = values.prefix(arrayLimit).map { describe($0 as CFTypeRef, arrayLimit: arrayLimit) }
            if values.count > arrayLimit {
                descriptions.append("truncated=\(values.count - arrayLimit)")
            }
            return bounded("[\(descriptions.joined(separator: ", "))]")
        }
        return bounded(String(describing: value))
    }

    private static func describeAXValue(_ value: AXValue) -> String {
        switch AXValueGetType(value) {
        case .cgPoint:
            var point = CGPoint.zero
            AXValueGetValue(value, .cgPoint, &point)
            return "point(x=\(point.x),y=\(point.y))"
        case .cgSize:
            var size = CGSize.zero
            AXValueGetValue(value, .cgSize, &size)
            return "size(w=\(size.width),h=\(size.height))"
        case .cgRect:
            var rect = CGRect.zero
            AXValueGetValue(value, .cgRect, &rect)
            return "rect(x=\(rect.minX),y=\(rect.minY),w=\(rect.width),h=\(rect.height))"
        case .cfRange:
            var range = CFRange()
            AXValueGetValue(value, .cfRange, &range)
            return "range(location=\(range.location),length=\(range.length))"
        default:
            return "axvalue"
        }
    }

    private static func describeElement(_ element: AXUIElement) -> String {
        "AXUIElement(reference=\(CFHash(element)))"
    }

    private static func bounded(_ value: String) -> String {
        RuntimeTraceLimits.boundedString(value)
    }
}
