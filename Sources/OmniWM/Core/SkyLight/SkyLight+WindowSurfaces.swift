// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

extension SkyLight {
    func getWindowTitle(_ windowId: UInt32) -> String? {
        let options: CGWindowListOption = [.optionIncludingWindow]
        guard let windowList = CGWindowListCopyWindowInfo(options, CGWindowID(windowId)) as? [[String: Any]],
              let windowInfo = windowList.first,
              let title = windowInfo[kCGWindowName as String] as? String
        else { return nil }
        return title
    }

    func createBorderWindow(frame: CGRect) -> UInt32 {
        let cid = getMainConnectionID()
        guard cid != 0 else { return 0 }

        var region: CFTypeRef?
        var rect = frame
        _ = surfaces.newRegionWithRect(&rect, &region)
        guard let region else { return 0 }

        var wid: UInt32 = 0
        if surfaces.newWindow(cid, 2, -9999, -9999, region, &wid) != .success {
            FallbackFiringRecorder.shared.note(.skylight, "newWindowFailed")
        }
        return wid
    }

    func releaseBorderWindow(_ wid: UInt32) {
        let cid = getMainConnectionID()
        guard cid != 0 else { return }
        if surfaces.releaseWindow(cid, wid) != .success {
            FallbackFiringRecorder.shared.note(.skylight, "releaseWindowFailed")
        }
    }

    @discardableResult
    func setWindowShape(_ wid: UInt32, frame: CGRect) -> Bool {
        let cid = getMainConnectionID()
        guard cid != 0 else { return false }

        var region: CFTypeRef?
        var rect = frame
        _ = surfaces.newRegionWithRect(&rect, &region)
        guard let region else { return false }

        let ok = surfaces.setWindowShape(cid, wid, -9999, -9999, region) == .success
        if !ok { FallbackFiringRecorder.shared.note(.skylight, "setWindowShapeFailed") }
        return ok
    }

    @discardableResult
    func configureWindow(_ wid: UInt32, resolution: Float, opaque: Bool) -> (resolution: Bool, opacity: Bool) {
        let cid = getMainConnectionID()
        guard cid != 0 else { return (false, false) }
        let resolutionOk = surfaces.setWindowResolution(cid, wid, resolution) == .success
        let opacityOk = surfaces.setWindowOpacity(cid, wid, opaque ? 1 : 0) == .success
        if !opacityOk { FallbackFiringRecorder.shared.note(.skylight, "setWindowOpacityFailed") }
        return (resolutionOk, opacityOk)
    }

    @discardableResult
    func setWindowBackgroundBlurRadius(_ wid: UInt32, radius: Int) -> Bool {
        let cid = getMainConnectionID()
        guard cid != 0, let setWindowBackgroundBlurRadius = surfaces.setWindowBackgroundBlurRadius else { return false }
        let ok = setWindowBackgroundBlurRadius(cid, wid, Int32(radius)) == .success
        if !ok { FallbackFiringRecorder.shared.note(.skylight, "setWindowBackgroundBlurRadiusFailed") }
        return ok
    }

    @discardableResult
    func setWindowTags(_ wid: UInt32, tags: UInt64) -> Bool {
        let cid = getMainConnectionID()
        guard cid != 0 else { return false }
        var tagsValue = tags
        let ok = surfaces.setWindowTags(cid, wid, &tagsValue, 64) == .success
        if !ok { FallbackFiringRecorder.shared.note(.skylight, "setWindowTagsFailed") }
        return ok
    }

    @discardableResult
    func excludeFromScreencaptureWindowSelection(_ wid: UInt32) -> Bool {
        let cid = getMainConnectionID()
        guard cid != 0, let setWindowProperty = surfaces.setWindowProperty else {
            FallbackFiringRecorder.shared.note(.skylight, "screencaptureSelectionExclusionUnavailable")
            return false
        }
        let ok = setWindowProperty(cid, wid, screencaptureSelectionExclusionKey, kCFBooleanTrue) == .success
        if !ok { FallbackFiringRecorder.shared.note(.skylight, "screencaptureSelectionExclusionFailed") }
        return ok
    }

    func isExcludedFromScreencaptureWindowSelection(_ wid: UInt32) -> Bool? {
        let cid = getMainConnectionID()
        guard cid != 0, let copyWindowProperty = surfaces.copyWindowProperty else { return nil }
        var value: CFTypeRef?
        guard copyWindowProperty(cid, wid, screencaptureSelectionExclusionKey, &value) == .success,
              let value
        else { return nil }
        return (value as AnyObject) === (kCFBooleanTrue as AnyObject)
    }

    @discardableResult
    func flushWindow(_ wid: UInt32) -> Bool {
        let cid = getMainConnectionID()
        guard cid != 0 else { return false }
        let ok = surfaces.flushWindowContentRegion(cid, wid, nil) == .success
        if !ok { FallbackFiringRecorder.shared.note(.skylight, "flushWindowFailed") }
        return ok
    }
}
