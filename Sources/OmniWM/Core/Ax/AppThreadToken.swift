import Foundation

@TaskLocal
var appThreadToken: AppThreadToken?

struct AppThreadToken: Sendable, Equatable, CustomStringConvertible {
    let pid: pid_t
    let bundleId: String?

    init(pid: pid_t, bundleId: String?) {
        self.pid = pid
        self.bundleId = bundleId
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.pid == rhs.pid }

    func checkEquals(_ other: AppThreadToken?) {
        precondition(self == other, "Thread token mismatch: \(self) != \(String(describing: other))")
    }

    var description: String {
        bundleId ?? "pid:\(pid)"
    }
}
