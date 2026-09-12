// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation

struct AutomaticAXSnapshotRead {
    let snapshot: AXDirectSnapshot
    let values: [Any?]?
    let succeeded: Bool

    static func read(
        element: AXUIElement,
        attributes: [String],
        writableAttributes: [String],
        deadline: TimeInterval
    ) -> AutomaticAXSnapshotRead {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            return AutomaticAXSnapshotRead(
                snapshot: AXDirectSnapshot(
                    attributes: [:],
                    writable: [],
                    failures: ["deadline_exceeded"]
                ),
                values: nil,
                succeeded: false
            )
        }
        var copiedValues: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &copiedValues
        )
        var failures: [String] = []
        let values = describedAttributes(
            copiedValues,
            result: result,
            attributes: attributes,
            deadline: deadline,
            failures: &failures
        )

        let writable = readWritableAttributes(
            element,
            attributes: writableAttributes,
            deadline: deadline,
            failures: &failures
        )
        return AutomaticAXSnapshotRead(
            snapshot: AXDirectSnapshot(
                attributes: values,
                writable: writable.sorted(),
                failures: failures.sorted()
            ),
            values: copiedValues as? [Any?],
            succeeded: result == .success && !values.isEmpty
        )
    }

    private static func describedAttributes(
        _ copiedValues: CFArray?,
        result: AXError,
        attributes: [String],
        deadline: TimeInterval,
        failures: inout [String]
    ) -> [String: String] {
        var values: [String: String] = [:]
        if result == .success, let copiedValues = copiedValues as? [Any?] {
            for (index, attribute) in attributes.enumerated() {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    failures.append("deadline_exceeded")
                    break
                }
                guard index < copiedValues.count,
                      let value = copiedValues[index],
                      !(value is NSError)
                else {
                    failures.append(attribute)
                    continue
                }
                let cfValue = value as CFTypeRef
                if let error = attributeError(cfValue) {
                    failures.append("\(attribute)(ax=\(error.rawValue))")
                    continue
                }
                values[attribute] = AXSnapshotValueFormatter.describe(
                    cfValue,
                    arrayLimit: RuntimeTraceLimits.axArrayElements
                )
            }
        } else {
            failures.append("AXCopyMultipleAttributeValues(ax=\(result.rawValue))")
        }

        return values
    }

    private static func attributeError(_ value: CFTypeRef) -> AXError? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(value) == .axError else { return nil }
        var error = AXError.success
        guard AXValueGetValue(value, .axError, &error) else { return nil }
        return error
    }

    private static func readWritableAttributes(
        _ element: AXUIElement,
        attributes: [String],
        deadline: TimeInterval,
        failures: inout [String]
    ) -> [String] {
        var writable: [String] = []
        for attribute in attributes {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                failures.append("deadline_exceeded")
                break
            }
            var settable = DarwinBoolean(false)
            let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
            if status == .success {
                if settable.boolValue {
                    writable.append(attribute)
                }
            } else {
                failures.append("\(attribute).settable(ax=\(status.rawValue))")
            }
        }
        return writable
    }
}
