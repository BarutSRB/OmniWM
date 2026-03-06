import CZigLayout
import Foundation

enum ZigNiriLayoutKernel {
    final class LayoutContext {
        fileprivate let raw: OpaquePointer

        init?() {
            guard let raw = omni_niri_runtime_create() else { return nil }
            self.raw = raw
        }

        @inline(__always)
        func withRawContext<T>(_ body: (OpaquePointer) -> T) -> T {
            body(raw)
        }

        deinit {
            omni_niri_runtime_destroy(raw)
        }
    }
}
