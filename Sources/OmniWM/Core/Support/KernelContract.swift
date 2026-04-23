// SPDX-License-Identifier: GPL-2.0-only
import Foundation

enum KernelContract {
    static func require<T>(
        _ value: T?,
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> T {
        guard let value else {
            preconditionFailure("Kernel contract violation: \(message())", file: file, line: line)
        }
        return value
    }
}
