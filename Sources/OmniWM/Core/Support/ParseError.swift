// SPDX-License-Identifier: GPL-2.0-only
import Foundation

struct ParseError: Error, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String {
        message
    }
}
