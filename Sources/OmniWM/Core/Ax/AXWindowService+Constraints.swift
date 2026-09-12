// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

extension AXWindowService {
    private static func sizeValue(_ value: CFTypeRef?) -> CGSize? {
        guard let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgSize, &size) else { return nil }
        return size
    }

    static func sizeValue(_ value: Any?) -> CGSize? {
        guard let value else { return nil }
        return sizeValue(value as CFTypeRef)
    }

    static func sizeConstraintInputs(
        from values: CFArray,
        currentSize: CGSize?
    ) -> AXWindowConstraintInputs {
        AXWindowConstraintInputs(
            hasGrowArea: AXAttributeValue.isElement(AXAttributeValue.value(at: 0, in: values)),
            hasZoomButton: AXAttributeValue.isElement(AXAttributeValue.value(at: 1, in: values)),
            subrole: AXAttributeValue.stringValue(AXAttributeValue.value(at: 2, in: values)),
            minSize: sizeValue(AXAttributeValue.value(at: 3, in: values)),
            maxSize: sizeValue(AXAttributeValue.value(at: 4, in: values)),
            currentSize: currentSize
        )
    }

    static func resolvedSizeConstraints(_ inputs: AXWindowConstraintInputs) -> WindowSizeConstraints {
        let resizable = inputs.hasGrowArea
            || inputs.hasZoomButton
            || inputs.subrole == (kAXStandardWindowSubrole as String)
        if !resizable {
            return inputs.currentSize.map(WindowSizeConstraints.fixed(size:)) ?? .unconstrained
        }
        return WindowSizeConstraints(
            minSize: inputs.minSize ?? CGSize(width: 100, height: 100),
            maxSize: inputs.maxSize ?? .zero,
            isFixed: false
        )
    }

    static func sizeConstraints(_ window: AXWindowRef, currentSize: CGSize? = nil) -> WindowSizeConstraints {
        MainThreadAXSpanTrace.measure(.readSizeConstraints, windowId: window.windowId) {
            fetchSizeConstraintsBatched(window, currentSize: currentSize)
        }
    }

    private static func fetchSizeConstraintsBatched(
        _ window: AXWindowRef,
        currentSize: CGSize? = nil
    ) -> WindowSizeConstraints {
        let attributes: [CFString] = [
            "AXGrowArea" as CFString,
            kAXZoomButtonAttribute as CFString,
            kAXSubroleAttribute as CFString,
            "AXMinSize" as CFString,
            "AXMaxSize" as CFString
        ]

        var values: CFArray?
        let attributesCFArray = attributes as CFArray
        let result = AXUIElementCopyMultipleAttributeValues(
            window.element,
            attributesCFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &values
        )

        let observedSize = currentSize ?? (try? frame(window).size)
        let inputs = if result == .success, let values {
            sizeConstraintInputs(from: values, currentSize: observedSize)
        } else {
            AXWindowConstraintInputs(
                hasGrowArea: false,
                hasZoomButton: false,
                subrole: nil,
                minSize: nil,
                maxSize: nil,
                currentSize: observedSize
            )
        }

        return resolvedSizeConstraints(inputs)
    }
}
