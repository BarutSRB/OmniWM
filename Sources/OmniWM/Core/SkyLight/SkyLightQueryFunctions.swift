// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct SkyLightQueryFunctions {
    typealias WindowQueryWindowsFunc = @convention(c) (Int32, CFArray, UInt32) -> Unmanaged<CFTypeRef>?
    typealias WindowQueryResultCopyWindowsFunc = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    typealias WindowIteratorGetCountFunc = @convention(c) (CFTypeRef) -> Int32
    typealias WindowIteratorAdvanceFunc = @convention(c) (CFTypeRef) -> Bool
    typealias WindowIteratorGetCornerRadiiFunc = @convention(c) (
        CFTypeRef,
        CFIndex
    ) -> Unmanaged<CFArray>?
    typealias WindowIteratorGetBoundsFunc = @convention(c) (CFTypeRef) -> CGRect
    typealias WindowIteratorGetWindowIDFunc = @convention(c) (CFTypeRef) -> UInt32
    typealias WindowIteratorGetPIDFunc = @convention(c) (CFTypeRef) -> Int32
    typealias WindowIteratorGetLevelFunc = @convention(c) (CFTypeRef) -> Int32
    typealias WindowIteratorGetTagsFunc = @convention(c) (CFTypeRef) -> UInt64
    typealias WindowIteratorGetAttributesFunc = @convention(c) (CFTypeRef) -> UInt32
    typealias WindowIteratorGetParentIDFunc = @convention(c) (CFTypeRef) -> UInt32

    let windowQueryWindows: WindowQueryWindowsFunc
    let windowQueryResultCopyWindows: WindowQueryResultCopyWindowsFunc
    let windowIteratorGetCount: WindowIteratorGetCountFunc
    let windowIteratorAdvance: WindowIteratorAdvanceFunc
    let windowIteratorGetCornerRadii: WindowIteratorGetCornerRadiiFunc
    let windowIteratorGetResolvedCornerRadii: WindowIteratorGetCornerRadiiFunc?
    let windowIteratorGetBounds: WindowIteratorGetBoundsFunc
    let windowIteratorGetWindowID: WindowIteratorGetWindowIDFunc
    let windowIteratorGetPID: WindowIteratorGetPIDFunc
    let windowIteratorGetLevel: WindowIteratorGetLevelFunc
    let windowIteratorGetTags: WindowIteratorGetTagsFunc
    let windowIteratorGetAttributes: WindowIteratorGetAttributesFunc
    let windowIteratorGetParentID: WindowIteratorGetParentIDFunc

    init(resolver: inout SkyLightSymbolResolver) {
        windowQueryWindows = resolver.resolve("SLSWindowQueryWindows", as: WindowQueryWindowsFunc.self)
        windowQueryResultCopyWindows = resolver.resolve(
            "SLSWindowQueryResultCopyWindows",
            as: WindowQueryResultCopyWindowsFunc.self
        )
        windowIteratorGetCount = resolver.resolve("SLSWindowIteratorGetCount", as: WindowIteratorGetCountFunc.self)
        windowIteratorAdvance = resolver.resolve("SLSWindowIteratorAdvance", as: WindowIteratorAdvanceFunc.self)
        windowIteratorGetCornerRadii = resolver.resolve(
            "SLSWindowIteratorGetCornerRadii",
            as: WindowIteratorGetCornerRadiiFunc.self
        )
        windowIteratorGetResolvedCornerRadii = resolver.resolveOptional(
            "SLSWindowIteratorGetResolvedCornerRadii",
            as: WindowIteratorGetCornerRadiiFunc.self
        )
        windowIteratorGetBounds = resolver.resolve("SLSWindowIteratorGetBounds", as: WindowIteratorGetBoundsFunc.self)
        windowIteratorGetWindowID = resolver.resolve(
            "SLSWindowIteratorGetWindowID",
            as: WindowIteratorGetWindowIDFunc.self
        )
        windowIteratorGetPID = resolver.resolve("SLSWindowIteratorGetPID", as: WindowIteratorGetPIDFunc.self)
        windowIteratorGetLevel = resolver.resolve("SLSWindowIteratorGetLevel", as: WindowIteratorGetLevelFunc.self)
        windowIteratorGetTags = resolver.resolve("SLSWindowIteratorGetTags", as: WindowIteratorGetTagsFunc.self)
        windowIteratorGetAttributes = resolver.resolve(
            "SLSWindowIteratorGetAttributes",
            as: WindowIteratorGetAttributesFunc.self
        )
        windowIteratorGetParentID = resolver.resolve(
            "SLSWindowIteratorGetParentID",
            as: WindowIteratorGetParentIDFunc.self
        )
    }
}
