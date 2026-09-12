// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

extension AXWindowService {
    private enum WindowTypeAttributeIndex: Int {
        case role
        case subrole
        case closeButton
        case fullScreenButton
        case zoomButton
        case minimizeButton
        case main
        case modal
        case title
    }

    static func collectWindowFacts(
        _ window: AXWindowRef,
        appPolicy: NSApplication.ActivationPolicy?,
        bundleId: String? = nil,
        includeTitle: Bool
    ) -> AXWindowFacts {
        MainThreadAXSpanTrace.measure(.readWindowFacts, windowId: window.windowId) {
            var attributes: [CFString] = [
                kAXRoleAttribute as CFString,
                kAXSubroleAttribute as CFString,
                kAXCloseButtonAttribute as CFString,
                kAXFullScreenButtonAttribute as CFString,
                kAXZoomButtonAttribute as CFString,
                kAXMinimizeButtonAttribute as CFString,
                kAXMainAttribute as CFString,
                kAXModalAttribute as CFString
            ]
            if includeTitle {
                attributes.append(kAXTitleAttribute as CFString)
            }

            var values: CFArray?
            let result = AXUIElementCopyMultipleAttributeValues(
                window.element,
                attributes as CFArray,
                AXCopyMultipleAttributeOptions(rawValue: 0),
                &values
            )

            guard result == .success,
                  let values,
                  CFArrayGetCount(values) > WindowTypeAttributeIndex.modal.rawValue
            else {
                return AXWindowDecisionEvidence.unavailable(
                    appPolicy: appPolicy,
                    bundleId: bundleId
                ).facts
            }

            return collectedWindowFacts(values, appPolicy: appPolicy, bundleId: bundleId, includeTitle: includeTitle)
        }
    }

    private static func collectedWindowFacts(
        _ values: CFArray,
        appPolicy: NSApplication.ActivationPolicy?,
        bundleId: String?,
        includeTitle: Bool
    ) -> AXWindowFacts {
        func attributeValue(_ index: WindowTypeAttributeIndex) -> CFTypeRef? {
            AXAttributeValue.value(at: index.rawValue, in: values)
        }

        let fullscreenButtonValue = attributeValue(.fullScreenButton)
        let buttonState = fullscreenButtonState(fullscreenButtonValue)
        return makeWindowFacts(
            AXWindowFactAttributeValues(
                role: AXAttributeValue.stringValue(attributeValue(.role)),
                subrole: AXAttributeValue.stringValue(attributeValue(.subrole)),
                title: includeTitle ? AXAttributeValue.stringValue(attributeValue(.title)) : nil,
                closeButton: attributeValue(.closeButton),
                fullscreenButton: fullscreenButtonValue,
                fullscreenButtonEnabled: buttonState.enabled,
                zoomButton: attributeValue(.zoomButton),
                minimizeButton: attributeValue(.minimizeButton),
                main: attributeValue(.main),
                modal: attributeValue(.modal)
            ),
            appPolicy: appPolicy,
            bundleId: bundleId,
            attributeFetchSucceeded: buttonState.succeeded
        )
    }

    private static func fullscreenButtonState(_ value: CFTypeRef?) -> (enabled: Bool?, succeeded: Bool) {
        let evidence = fullscreenButtonEvidence(value)
        var attributeFetchSucceeded = evidence.succeeded

        var fullscreenButtonEnabled: Bool?
        if let buttonElement = evidence.element {
            var enabledValue: CFTypeRef?
            let enabledResult = AXUIElementCopyAttributeValue(
                buttonElement,
                kAXEnabledAttribute as CFString,
                &enabledValue
            )
            if enabledResult == .success {
                if let enabledValue {
                    if let resolvedEnabled = enabledValue as? Bool {
                        fullscreenButtonEnabled = resolvedEnabled
                    } else {
                        attributeFetchSucceeded = false
                    }
                }
            }
        }

        return (fullscreenButtonEnabled, attributeFetchSucceeded)
    }

    static func makeWindowFacts(
        _ attributes: AXWindowFactAttributeValues,
        appPolicy: NSApplication.ActivationPolicy?,
        bundleId: String?,
        attributeFetchSucceeded: Bool
    ) -> AXWindowFacts {
        AXWindowFacts(
            role: attributes.role,
            subrole: attributes.subrole,
            title: attributes.title,
            hasCloseButton: resolvedAttribute(attributes.closeButton),
            hasFullscreenButton: resolvedAttribute(attributes.fullscreenButton),
            fullscreenButtonEnabled: attributes.fullscreenButtonEnabled,
            hasZoomButton: resolvedAttribute(attributes.zoomButton),
            hasMinimizeButton: resolvedAttribute(attributes.minimizeButton),
            appPolicy: appPolicy,
            bundleId: bundleId,
            attributeFetchSucceeded: attributeFetchSucceeded,
            isMain: attributes.main as? Bool,
            isModal: attributes.modal as? Bool
        )
    }

    static func resolvedAttribute(_ value: Any?) -> Bool {
        guard let value else { return false }
        return AXAttributeValue.isElement(value as CFTypeRef)
    }

    static func fullscreenButtonEvidence(_ value: Any?) -> AXFullscreenButtonEvidence {
        guard let value else { return .absent }
        let cfValue = value as CFTypeRef
        let typeId = CFGetTypeID(cfValue)
        if typeId == CFNullGetTypeID() {
            return .absent
        }
        if typeId == AXUIElementGetTypeID() {
            return .present(unsafeDowncast(cfValue, to: AXUIElement.self))
        }
        guard typeId == AXValueGetTypeID() else {
            return .failed
        }
        let axValue = unsafeDowncast(cfValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .axError else {
            return .failed
        }
        var error = AXError.success
        guard AXValueGetValue(axValue, .axError, &error) else {
            return .failed
        }
        switch error {
        case .noValue,
             .attributeUnsupported:
            return .absent
        default:
            return .failed
        }
    }

    static func heuristicDisposition(
        for facts: AXWindowFacts,
        overriddenWindowType: AXWindowType? = nil
    ) -> AXWindowHeuristicDisposition {
        if let overriddenWindowType {
            let disposition: WindowDecisionDisposition = overriddenWindowType == .tiling ? .managed : .floating
            return AXWindowHeuristicDisposition(disposition: disposition, reasons: [])
        }

        if !facts.attributeFetchSucceeded {
            return AXWindowHeuristicDisposition(
                disposition: .undecided,
                reasons: [.attributeFetchFailed]
            )
        }

        let hasAnyButton = facts.hasCloseButton
            || facts.hasFullscreenButton
            || facts.hasZoomButton
            || facts.hasMinimizeButton

        if facts.appPolicy == .accessory && !facts.hasCloseButton {
            return AXWindowHeuristicDisposition(
                disposition: .floating,
                reasons: [.accessoryWithoutClose]
            )
        }

        if !hasAnyButton && facts.subrole != kAXStandardWindowSubrole as String {
            return AXWindowHeuristicDisposition(
                disposition: .floating,
                reasons: [.noButtonsOnNonStandardSubrole]
            )
        }

        if let subrole = facts.subrole,
           subrole != (kAXStandardWindowSubrole as String)
        {
            return AXWindowHeuristicDisposition(
                disposition: .floating,
                reasons: [.nonStandardSubrole]
            )
        }

        if !facts.hasFullscreenButton {
            return AXWindowHeuristicDisposition(
                disposition: .floating,
                reasons: [.missingFullscreenButton]
            )
        }

        if facts.fullscreenButtonEnabled != true {
            return AXWindowHeuristicDisposition(
                disposition: .floating,
                reasons: [.disabledFullscreenButton]
            )
        }

        return AXWindowHeuristicDisposition(
            disposition: .managed,
            reasons: []
        )
    }
}
