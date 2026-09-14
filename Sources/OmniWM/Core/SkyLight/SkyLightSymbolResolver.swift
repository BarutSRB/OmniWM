// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct SkyLightSymbolResolver {
    private let library: UnsafeMutableRawPointer
    private(set) var capabilitySymbols: [String] = []

    init() {
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            fatalError("Failed to load SkyLight framework")
        }
        self.library = library
    }

    mutating func resolve<T>(_ symbol: String, as _: T.Type) -> T {
        guard let pointer = dlsym(library, symbol) else {
            fatalError("SkyLight missing required symbol: \(symbol)")
        }
        capabilitySymbols.append(symbol)
        return unsafeBitCast(pointer, to: T.self)
    }

    mutating func resolveOptional<T>(_ symbol: String, as _: T.Type) -> T? {
        guard let pointer = dlsym(library, symbol) else { return nil }
        capabilitySymbols.append(symbol)
        return unsafeBitCast(pointer, to: T.self)
    }
}
