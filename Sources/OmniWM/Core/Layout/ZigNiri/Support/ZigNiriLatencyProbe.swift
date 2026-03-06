import Dispatch
import Foundation

enum ZigNiriLatencyHotPath: String, CaseIterable, Codable {
    case layoutPass
    case windowMove
    case resizeDragUpdate
    case navigationStep
    case workspaceMove
}

struct ZigNiriLatencyStats: Codable, Equatable {
    let count: Int
    let minMs: Double
    let meanMs: Double
    let p50Ms: Double
    let p95Ms: Double
    let p99Ms: Double
    let maxMs: Double

    static let empty = ZigNiriLatencyStats(
        count: 0,
        minMs: 0,
        meanMs: 0,
        p50Ms: 0,
        p95Ms: 0,
        p99Ms: 0,
        maxMs: 0
    )

    static func from(samplesNanoseconds: [UInt64]) -> ZigNiriLatencyStats {
        guard !samplesNanoseconds.isEmpty else {
            return .empty
        }

        let sorted = samplesNanoseconds.sorted()
        let count = sorted.count
        let minValue = sorted[0]
        let maxValue = sorted[count - 1]

        var totalNanoseconds: Double = 0
        for value in sorted {
            totalNanoseconds += Double(value)
        }

        let p50 = nearestRank(sorted: sorted, percentile: 0.50)
        let p95 = nearestRank(sorted: sorted, percentile: 0.95)
        let p99 = nearestRank(sorted: sorted, percentile: 0.99)

        return ZigNiriLatencyStats(
            count: count,
            minMs: toMilliseconds(minValue),
            meanMs: toMilliseconds(totalNanoseconds / Double(count)),
            p50Ms: toMilliseconds(p50),
            p95Ms: toMilliseconds(p95),
            p99Ms: toMilliseconds(p99),
            maxMs: toMilliseconds(maxValue)
        )
    }

    private static func nearestRank(sorted: [UInt64], percentile: Double) -> UInt64 {
        guard !sorted.isEmpty else { return 0 }
        let count = sorted.count
        let rank = max(1, Int(ceil(percentile * Double(count))))
        let index = min(count - 1, rank - 1)
        return sorted[index]
    }

    private static func toMilliseconds(_ nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000.0
    }

    private static func toMilliseconds(_ nanoseconds: Double) -> Double {
        nanoseconds / 1_000_000.0
    }
}

enum ZigNiriLatencyProbe {
    static let environmentKey = "OMNI_NIRI_PHASE0_BENCH"

    private static let enabled = ProcessInfo.processInfo.environment[environmentKey] == "1"
    private static let hotPaths = ZigNiriLatencyHotPath.allCases
    private static let initialSampleCapacity = 1_024
    private static let hotPathIndices = Dictionary(
        uniqueKeysWithValues: hotPaths.enumerated().map { ($1, $0) }
    )
    private nonisolated(unsafe) static var samplesByPathIndex: [[UInt64]] = {
        var buffers = Array(repeating: [UInt64](), count: hotPaths.count)
        for index in buffers.indices {
            buffers[index].reserveCapacity(initialSampleCapacity)
        }
        return buffers
    }()
    private static let lock = NSLock()

    static var isEnabled: Bool {
        enabled
    }

    @inline(__always)
    static func measure<T>(_ hotPath: ZigNiriLatencyHotPath, _ body: () throws -> T) rethrows -> T {
        guard enabled else {
            return try body()
        }

        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let end = DispatchTime.now().uptimeNanoseconds
            record(hotPath, elapsedNanoseconds: end &- start)
        }
        return try body()
    }

    static func record(_ hotPath: ZigNiriLatencyHotPath, elapsedNanoseconds: UInt64) {
        guard enabled, let hotPathIndex = hotPathIndices[hotPath] else { return }
        lock.lock()
        samplesByPathIndex[hotPathIndex].append(elapsedNanoseconds)
        lock.unlock()
    }

    @inline(__always)
    static func begin(_ hotPath: ZigNiriLatencyHotPath) -> (hotPath: ZigNiriLatencyHotPath, startedAt: UInt64)? {
        guard enabled else { return nil }
        return (hotPath: hotPath, startedAt: DispatchTime.now().uptimeNanoseconds)
    }

    @inline(__always)
    static func end(_ token: (hotPath: ZigNiriLatencyHotPath, startedAt: UInt64)?) {
        guard let token else { return }
        let endTime = DispatchTime.now().uptimeNanoseconds
        record(token.hotPath, elapsedNanoseconds: endTime &- token.startedAt)
    }

    static func reset() {
        guard enabled else { return }

        lock.lock()
        for index in samplesByPathIndex.indices {
            samplesByPathIndex[index].removeAll(keepingCapacity: true)
        }
        lock.unlock()
    }

    static func snapshot() -> [ZigNiriLatencyHotPath: ZigNiriLatencyStats] {
        guard enabled else {
            return emptySnapshot()
        }

        lock.lock()
        let captured = samplesByPathIndex
        lock.unlock()

        var result: [ZigNiriLatencyHotPath: ZigNiriLatencyStats] = [:]
        result.reserveCapacity(hotPaths.count)
        for (index, hotPath) in hotPaths.enumerated() {
            let samples = captured.indices.contains(index) ? captured[index] : []
            result[hotPath] = ZigNiriLatencyStats.from(samplesNanoseconds: samples)
        }
        return result
    }

    static func emptySnapshot() -> [ZigNiriLatencyHotPath: ZigNiriLatencyStats] {
        var result: [ZigNiriLatencyHotPath: ZigNiriLatencyStats] = [:]
        result.reserveCapacity(hotPaths.count)
        for hotPath in hotPaths {
            result[hotPath] = .empty
        }
        return result
    }
}
