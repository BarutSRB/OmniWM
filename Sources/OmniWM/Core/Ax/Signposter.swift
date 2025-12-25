import Foundation
import os

let signposter = OSSignposter(subsystem: "com.omniwm.OmniWM", category: .pointsOfInterest)

@MainActor
struct SignpostInterval {
    private let state: OSSignpostIntervalState
    private let name: StaticString

    init(_ name: StaticString, _ message: String = "") {
        self.name = name
        state = signposter.beginInterval(name, "\(message)")
    }

    func end() {
        signposter.endInterval(name, state)
    }
}

@MainActor
func signpostInterval(_ name: StaticString, _ message: String = "") -> SignpostInterval {
    SignpostInterval(name, message)
}

@MainActor
func withSignpost<T>(_ name: StaticString, _ message: String = "", _ body: () throws -> T) rethrows -> T {
    let interval = signpostInterval(name, message)
    defer { interval.end() }
    return try body()
}

@MainActor
func withSignpost<T>(_ name: StaticString, _ message: String = "", _ body: () async throws -> T) async rethrows -> T {
    let interval = signpostInterval(name, message)
    defer { interval.end() }
    return try await body()
}

struct SignpostIntervalNonIsolated: Sendable {
    private let state: OSSignpostIntervalState
    private let name: StaticString

    init(_ name: StaticString, _ message: String = "") {
        self.name = name
        state = signposter.beginInterval(name, "\(message)")
    }

    func end() {
        signposter.endInterval(name, state)
    }
}

func signpostIntervalNonIsolated(_ name: StaticString, _ message: String = "") -> SignpostIntervalNonIsolated {
    SignpostIntervalNonIsolated(name, message)
}
