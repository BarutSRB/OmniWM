import Foundation

final class ThreadGuardedValue<Value>: Sendable {
    nonisolated(unsafe) private var _value: Value?
    private let threadToken: AppThreadToken

    init(_ value: Value) {
        guard let token = appThreadToken else {
            fatalError("appThreadToken is not initialized - must be called from within app thread context")
        }
        threadToken = token
        _value = value
    }

    var value: Value {
        get {
            threadToken.checkEquals(appThreadToken)
            guard let v = _value else {
                fatalError("Value is already destroyed")
            }
            return v
        }
        set(newValue) {
            threadToken.checkEquals(appThreadToken)
            _value = newValue
        }
    }

    func destroy() {
        threadToken.checkEquals(appThreadToken)
        _value = nil
    }

    deinit {
        assert(_value == nil, "The Value must be explicitly destroyed on the appropriate thread before deinit")
    }
}
