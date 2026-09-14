// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct SkyLightSurfaceFunctions {
    typealias NewWindowFunc = @convention(c) (
        Int32,
        Int32,
        Float,
        Float,
        CFTypeRef,
        UnsafeMutablePointer<UInt32>
    ) -> CGError
    typealias ReleaseWindowFunc = @convention(c) (Int32, UInt32) -> CGError
    typealias SetWindowShapeFunc = @convention(c) (Int32, UInt32, Float, Float, CFTypeRef) -> CGError
    typealias SetWindowResolutionFunc = @convention(c) (Int32, UInt32, Float) -> CGError
    typealias SetWindowOpacityFunc = @convention(c) (Int32, UInt32, Int32) -> CGError
    typealias SetWindowBackgroundBlurRadiusFunc = @convention(c) (Int32, UInt32, Int32) -> CGError
    typealias SetWindowTagsFunc = @convention(c) (Int32, UInt32, UnsafePointer<UInt64>, Int32) -> CGError
    typealias SetWindowPropertyFunc = @convention(c) (Int32, UInt32, CFString, CFTypeRef) -> CGError
    typealias CopyWindowPropertyFunc = @convention(c) (
        Int32,
        UInt32,
        CFString,
        UnsafeMutablePointer<CFTypeRef?>
    ) -> CGError
    typealias FlushWindowContentRegionFunc = @convention(c) (Int32, UInt32, CFTypeRef?) -> CGError
    typealias NewRegionWithRectFunc = @convention(c) (UnsafePointer<CGRect>, UnsafeMutablePointer<CFTypeRef?>)
        -> CGError
    typealias TransactionSetWindowLevelFunc = @convention(c) (CFTypeRef, UInt32, Int32) -> Void

    let newWindow: NewWindowFunc
    let releaseWindow: ReleaseWindowFunc
    let setWindowShape: SetWindowShapeFunc
    let setWindowResolution: SetWindowResolutionFunc
    let setWindowOpacity: SetWindowOpacityFunc
    let setWindowBackgroundBlurRadius: SetWindowBackgroundBlurRadiusFunc?
    let setWindowTags: SetWindowTagsFunc
    let setWindowProperty: SetWindowPropertyFunc?
    let copyWindowProperty: CopyWindowPropertyFunc?
    let flushWindowContentRegion: FlushWindowContentRegionFunc
    let newRegionWithRect: NewRegionWithRectFunc
    let transactionSetWindowLevel: TransactionSetWindowLevelFunc

    init(resolver: inout SkyLightSymbolResolver) {
        newWindow = resolver.resolve("SLSNewWindow", as: NewWindowFunc.self)
        releaseWindow = resolver.resolve("SLSReleaseWindow", as: ReleaseWindowFunc.self)
        setWindowShape = resolver.resolve("SLSSetWindowShape", as: SetWindowShapeFunc.self)
        setWindowResolution = resolver.resolve("SLSSetWindowResolution", as: SetWindowResolutionFunc.self)
        setWindowOpacity = resolver.resolve("SLSSetWindowOpacity", as: SetWindowOpacityFunc.self)
        setWindowBackgroundBlurRadius = resolver.resolveOptional(
            "SLSSetWindowBackgroundBlurRadius",
            as: SetWindowBackgroundBlurRadiusFunc.self
        )
        setWindowTags = resolver.resolve("SLSSetWindowTags", as: SetWindowTagsFunc.self)
        setWindowProperty = resolver.resolveOptional("SLSSetWindowProperty", as: SetWindowPropertyFunc.self)
        copyWindowProperty = resolver.resolveOptional("SLSCopyWindowProperty", as: CopyWindowPropertyFunc.self)
        flushWindowContentRegion = resolver.resolve(
            "SLSFlushWindowContentRegion",
            as: FlushWindowContentRegionFunc.self
        )
        newRegionWithRect = resolver.resolve("CGSNewRegionWithRect", as: NewRegionWithRectFunc.self)
        transactionSetWindowLevel = resolver.resolve(
            "SLSTransactionSetWindowLevel",
            as: TransactionSetWindowLevelFunc.self
        )
    }
}
