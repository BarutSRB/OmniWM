// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct SkyLightConnectionFunctions {
    typealias MainConnectionIDFunc = @convention(c) () -> Int32
    typealias NewConnectionFunc = @convention(c) (Int32, UnsafeMutablePointer<Int32>) -> CGError
    typealias ReleaseConnectionFunc = @convention(c) (Int32) -> CGError

    let mainConnectionID: MainConnectionIDFunc
    let newConnection: NewConnectionFunc?
    let releaseConnection: ReleaseConnectionFunc?

    init(resolver: inout SkyLightSymbolResolver) {
        mainConnectionID = resolver.resolve("SLSMainConnectionID", as: MainConnectionIDFunc.self)
        newConnection = resolver.resolveOptional("SLSNewConnection", as: NewConnectionFunc.self)
        releaseConnection = resolver.resolveOptional("SLSReleaseConnection", as: ReleaseConnectionFunc.self)
    }
}
