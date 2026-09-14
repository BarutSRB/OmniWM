// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct SkyLightTransactionFunctions {
    typealias TransactionCreateFunc = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    typealias TransactionCommitFunc = @convention(c) (CFTypeRef, Int32) -> Void
    typealias TransactionOrderWindowFunc = @convention(c) (CFTypeRef, UInt32, Int32, UInt32) -> Void
    typealias WindowIsOrderedInFunc = @convention(c) (Int32, UInt32, UnsafeMutablePointer<UInt8>) -> CGError
    typealias TransactionMoveWindowWithGroupFunc = @convention(c) (CFTypeRef, UInt32, CGPoint) -> Void
    typealias MoveWindowFunc = @convention(c) (Int32, UInt32, UnsafePointer<CGPoint>) -> CGError
    typealias GetWindowBoundsFunc = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> CGError

    let transactionCreate: TransactionCreateFunc
    let transactionCommit: TransactionCommitFunc
    let transactionOrderWindow: TransactionOrderWindowFunc
    let windowIsOrderedIn: WindowIsOrderedInFunc
    let transactionMoveWindowWithGroup: TransactionMoveWindowWithGroupFunc
    let moveWindow: MoveWindowFunc
    let getWindowBounds: GetWindowBoundsFunc

    init(resolver: inout SkyLightSymbolResolver) {
        transactionCreate = resolver.resolve("SLSTransactionCreate", as: TransactionCreateFunc.self)
        transactionCommit = resolver.resolve("SLSTransactionCommit", as: TransactionCommitFunc.self)
        transactionOrderWindow = resolver.resolve("SLSTransactionOrderWindow", as: TransactionOrderWindowFunc.self)
        windowIsOrderedIn = resolver.resolve("SLSWindowIsOrderedIn", as: WindowIsOrderedInFunc.self)
        transactionMoveWindowWithGroup = resolver.resolve(
            "SLSTransactionMoveWindowWithGroup",
            as: TransactionMoveWindowWithGroupFunc.self
        )
        moveWindow = resolver.resolve("SLSMoveWindow", as: MoveWindowFunc.self)
        getWindowBounds = resolver.resolve("SLSGetWindowBounds", as: GetWindowBoundsFunc.self)
    }
}
