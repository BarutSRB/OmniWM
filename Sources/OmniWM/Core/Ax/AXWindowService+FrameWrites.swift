// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

extension AXWindowService {
    private struct FrameWriteOptions {
        let currentFrameHint: CGRect?
        let components: AXFrameComponents
        let verify: Bool
    }

    private enum FrameWriteAttribute {
        case size
        case position
    }

    static func frameWriteOrder(currentFrame: CGRect?, targetFrame: CGRect) -> AXFrameWriteOrder {
        guard let currentFrame else {
            return .sizeThenPosition
        }
        if targetFrame.width > currentFrame.width + 0.5 || targetFrame.height > currentFrame.height + 0.5 {
            return .positionThenSize
        }
        return .sizeThenPosition
    }

    static func setFrame(
        _ window: AXWindowRef,
        frame: CGRect,
        currentFrameHint: CGRect? = nil,
        components: AXFrameComponents = .all,
        verify: Bool = true
    ) -> AXFrameWriteResult {
        setFrame(
            window,
            frame: frame,
            options: FrameWriteOptions(currentFrameHint: currentFrameHint, components: components, verify: verify),
            timing: nil
        )
    }

    private static func setFrame(
        _ window: AXWindowRef,
        frame: CGRect,
        options: FrameWriteOptions,
        timing: UnsafeMutablePointer<AXFrameSetterTiming>?
    ) -> AXFrameWriteResult {
        let currentFrameHint = options.currentFrameHint
        let components = options.components
        let verify = options.verify
        precondition(!components.isEmpty)
        let writeOrder = components == .all
            ? frameWriteOrder(
                currentFrame: currentFrameHint ?? (try? self.frame(window)),
                targetFrame: frame
            )
            : .sizeThenPosition
        let axFrame = convertToAX(frame)
        var position = CGPoint(x: axFrame.origin.x, y: axFrame.origin.y)
        var size = CGSize(width: axFrame.size.width, height: axFrame.size.height)
        let positionValue = components.contains(.position) ? AXValueCreate(.cgPoint, &position) : nil
        let sizeValue = components.contains(.size) ? AXValueCreate(.cgSize, &size) : nil
        guard !components.contains(.position) || positionValue != nil,
              !components.contains(.size) || sizeValue != nil
        else {
            return .skipped(
                targetFrame: frame,
                currentFrameHint: currentFrameHint,
                failureReason: .valueCreationFailed,
                components: components
            )
        }

        let (sizeError, positionError) = setFrameAttributes(
            window, values: (sizeValue, positionValue), order: writeOrder, timing: timing
        )

        let verificationStart = timing == nil ? 0 : DispatchTime.now().uptimeNanoseconds
        let observedFrame = verify ? (try? self.frame(window)) : nil
        if let timing {
            timing.pointee.verificationNs = elapsedNanoseconds(since: verificationStart)
        }

        let failureReason = frameWriteFailure(
            errors: (sizeError, positionError), observedFrame: observedFrame, frame: frame, options: options
        )

        return AXFrameWriteResult(
            observedFrame: observedFrame,
            writeOrder: writeOrder,
            sizeError: sizeError,
            positionError: positionError,
            failureReason: failureReason,
            components: components
        )
    }

    static func setFrameTraced(
        _ window: AXWindowRef,
        frame: CGRect,
        currentFrameHint: CGRect? = nil,
        components: AXFrameComponents = .all,
        verify: Bool = true
    ) -> (result: AXFrameWriteResult, timing: AXFrameSetterTiming) {
        var timing = AXFrameSetterTiming()
        let result = withUnsafeMutablePointer(to: &timing) { pointer in
            setFrame(
                window,
                frame: frame,
                options: FrameWriteOptions(currentFrameHint: currentFrameHint, components: components, verify: verify),
                timing: pointer
            )
        }
        return (result, timing)
    }

    private static func frameWriteFailure(
        errors: (size: AXError, position: AXError),
        observedFrame: CGRect?,
        frame: CGRect,
        options: FrameWriteOptions
    ) -> AXFrameWriteFailureReason? {
        if errors.size != .success {
            mapFrameWriteFailure(errors.size, attribute: .size)
        } else if errors.position != .success {
            mapFrameWriteFailure(errors.position, attribute: .position)
        } else if !options.verify {
            nil
        } else if let observedFrame {
            axFrameMatches(observedFrame, target: frame, components: options.components) ? nil : .verificationMismatch
        } else {
            .readbackFailed
        }
    }

    private static func setFrameAttributes(
        _ window: AXWindowRef,
        values: (size: AXValue?, position: AXValue?),
        order: AXFrameWriteOrder,
        timing: UnsafeMutablePointer<AXFrameSetterTiming>?
    ) -> (AXError, AXError) {
        var positionError: AXError = .success
        var sizeError: AXError = .success

        func setSize() -> AXError {
            guard let sizeValue = values.size else { return .success }
            let start = timing == nil ? 0 : DispatchTime.now().uptimeNanoseconds
            let error = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, sizeValue)
            if let timing {
                timing.pointee.sizeNs = elapsedNanoseconds(since: start)
            }
            return error
        }

        func setPosition() -> AXError {
            guard let positionValue = values.position else { return .success }
            let start = timing == nil ? 0 : DispatchTime.now().uptimeNanoseconds
            let error = AXUIElementSetAttributeValue(
                window.element,
                kAXPositionAttribute as CFString,
                positionValue
            )
            if let timing {
                timing.pointee.positionNs = elapsedNanoseconds(since: start)
            }
            return error
        }

        switch order {
        case .sizeThenPosition:
            sizeError = setSize()
            positionError = setPosition()
        case .positionThenSize:
            positionError = setPosition()
            sizeError = setSize()
        }

        return (sizeError, positionError)
    }

    private static func elapsedNanoseconds(since start: UInt64) -> UInt64 {
        let end = DispatchTime.now().uptimeNanoseconds
        return end >= start ? end - start : 0
    }

    private static func convertToAX(_ rect: CGRect) -> CGRect {
        ScreenCoordinateSpace.toWindowServer(rect: rect)
    }

    private static func mapFrameWriteFailure(
        _ error: AXError,
        attribute: FrameWriteAttribute
    ) -> AXFrameWriteFailureReason {
        if error == .invalidUIElement || error == .cannotComplete {
            return .staleElement
        }

        return switch attribute {
        case .size:
            .sizeWriteFailed(error)
        case .position:
            .positionWriteFailed(error)
        }
    }
}
