// SPDX-License-Identifier: GPL-2.0-only
import Foundation

@TaskLocal
@usableFromInline
var appThreadToken: AppThreadToken?

@usableFromInline
struct AppThreadToken: Sendable, Equatable {
    @usableFromInline
    let pid: pid_t

    @inlinable
    init(pid: pid_t) {
        self.pid = pid
    }

    @usableFromInline
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.pid == rhs.pid }

    @inlinable
    func checkEquals(_ other: AppThreadToken?) {
        precondition(self == other)
    }
}
