// SPDX-License-Identifier: GPL-2.0-only
import Foundation

@usableFromInline
final class ThreadGuardedValue<Value>: Sendable {
    @usableFromInline
    nonisolated(unsafe) var storedValue: Value?

    @usableFromInline
    let threadToken: AppThreadToken

    init(_ value: Value) {
        guard let token = appThreadToken else {
            fatalError("appThreadToken is not initialized - must be called from within app thread context")
        }
        threadToken = token
        storedValue = value
    }

    @inlinable
    var value: Value {
        get {
            #if DEBUG
            threadToken.checkEquals(appThreadToken)
            guard let currentValue = storedValue else {
                fatalError("Value is already destroyed")
            }
            return currentValue
            #else
            return storedValue.unsafelyUnwrapped
            #endif
        }
        set(newValue) {
            #if DEBUG
            threadToken.checkEquals(appThreadToken)
            #endif
            storedValue = newValue
        }
    }

    @inlinable
    var valueIfExists: Value? {
        #if DEBUG
        threadToken.checkEquals(appThreadToken)
        #endif
        return storedValue
    }

    func destroy() {
        #if DEBUG
        threadToken.checkEquals(appThreadToken)
        #endif
        storedValue = nil
    }

    deinit {
        assert(storedValue == nil, "The Value must be explicitly destroyed on the appropriate thread before deinit")
    }

    @inlinable
    subscript<K: Hashable, V>(key: K) -> V? where Value == [K: V] {
        get {
            #if DEBUG
            threadToken.checkEquals(appThreadToken)
            #endif
            return storedValue?[key]
        }
        set {
            #if DEBUG
            threadToken.checkEquals(appThreadToken)
            #endif
            storedValue?[key] = newValue
        }
    }

    @inlinable
    func contains<T: Hashable>(_ element: T) -> Bool where Value == Set<T> {
        #if DEBUG
        threadToken.checkEquals(appThreadToken)
        #endif
        return storedValue?.contains(element) ?? false
    }

    @inlinable
    func insert<T: Hashable>(_ element: T) where Value == Set<T> {
        #if DEBUG
        threadToken.checkEquals(appThreadToken)
        #endif
        storedValue?.insert(element)
    }

    @inlinable
    @discardableResult
    func remove<T: Hashable>(_ element: T) -> T? where Value == Set<T> {
        #if DEBUG
        threadToken.checkEquals(appThreadToken)
        #endif
        return storedValue?.remove(element)
    }
}

extension ThreadGuardedValue {
    @inlinable
    func forEachKey<K: Hashable, V>(_ body: (K) -> Void) where Value == [K: V] {
        #if DEBUG
        threadToken.checkEquals(appThreadToken)
        #endif
        storedValue?.keys.forEach(body)
    }
}
