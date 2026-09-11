// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

extension AXWindowService {
    static func frame(_ window: AXWindowRef) throws(AXErrorWrapper) -> CGRect {
        try MainThreadAXSpanTrace
            .measure(.readFrame, windowId: window.windowId) { () throws(AXErrorWrapper) -> CGRect in
                let attributes = [
                    kAXPositionAttribute as CFString,
                    kAXSizeAttribute as CFString
                ] as CFArray
                var valuesPtr: CFArray?
                let result = AXUIElementCopyMultipleAttributeValues(
                    window.element,
                    attributes,
                    .init(),
                    &valuesPtr
                )
                guard result == .success,
                      let values = valuesPtr,
                      CFArrayGetCount(values) == 2,
                      let posRaw = AXAttributeValue.value(at: 0, in: values),
                      let sizeRaw = AXAttributeValue.value(at: 1, in: values)
                else { throw .cannotGetAttribute }
                guard CFGetTypeID(posRaw) == AXValueGetTypeID(),
                      CFGetTypeID(sizeRaw) == AXValueGetTypeID()
                else { throw .cannotGetAttribute }
                var pos = CGPoint.zero
                var size = CGSize.zero
                guard AXValueGetValue(unsafeDowncast(posRaw, to: AXValue.self), .cgPoint, &pos),
                      AXValueGetValue(unsafeDowncast(sizeRaw, to: AXValue.self), .cgSize, &size)
                else { throw .cannotGetAttribute }
                return convertFromAX(CGRect(origin: pos, size: size))
            }
    }

    @MainActor
    static func fastFrame(_ window: AXWindowRef) -> CGRect? {
        guard let frame = SkyLight.shared.getWindowBounds(UInt32(windowId(window))) else { return nil }
        return ScreenCoordinateSpace.toAppKit(rect: frame)
    }

    @MainActor
    static func framePreferFast(_ window: AXWindowRef) -> CGRect? {
        fastFrame(window)
    }

    private static func convertFromAX(_ rect: CGRect) -> CGRect {
        ScreenCoordinateSpace.toAppKit(rect: rect)
    }
}
