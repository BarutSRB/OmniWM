// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Carbon
import Foundation

struct HIDKeyboardModifierMapping: Codable, Equatable {
    let source: UInt64
    let destination: UInt64

    private enum CodingKeys: String, CodingKey {
        case source = "HIDKeyboardModifierMappingSrc"
        case destination = "HIDKeyboardModifierMappingDst"
    }
}

struct HIDKeyboardModifierMappingPayload: Codable, Equatable {
    let userKeyMapping: [HIDKeyboardModifierMapping]

    private enum CodingKeys: String, CodingKey {
        case userKeyMapping = "UserKeyMapping"
    }
}

enum CapsLockHyperMapping {
    static let capsLockSource: UInt64 = 0x700000039
    static let f18Destination: UInt64 = 0x70000006D
    static let f18KeyCode = UInt32(kVK_F18)

    static let omniMapping = HIDKeyboardModifierMapping(
        source: capsLockSource,
        destination: f18Destination
    )

    static func applying(to mappings: [HIDKeyboardModifierMapping]) -> [HIDKeyboardModifierMapping] {
        mappings.filter { $0.source != capsLockSource } + [omniMapping]
    }

    static func restoring(
        current: [HIDKeyboardModifierMapping],
        original: [HIDKeyboardModifierMapping]
    ) -> [HIDKeyboardModifierMapping] {
        var restored = current.filter { $0 != omniMapping }
        if !restored.contains(where: { $0.source == capsLockSource }) {
            restored.append(contentsOf: original.filter { $0.source == capsLockSource })
        }
        return restored
    }

    static func parseMappings(from data: Data) -> [HIDKeyboardModifierMapping] {
        if let payload = try? JSONDecoder().decode(HIDKeyboardModifierMappingPayload.self, from: data) {
            return payload.userKeyMapping
        }
        if let mappings = try? JSONDecoder().decode([HIDKeyboardModifierMapping].self, from: data) {
            return mappings
        }

        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let pattern = #"HIDKeyboardModifierMappingSrc\s*=\s*(\d+)[^}]*HIDKeyboardModifierMappingDst\s*=\s*(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges == 3,
                  let sourceRange = Range(match.range(at: 1), in: text),
                  let destinationRange = Range(match.range(at: 2), in: text),
                  let source = UInt64(text[sourceRange]),
                  let destination = UInt64(text[destinationRange])
            else { return nil }
            return HIDKeyboardModifierMapping(source: source, destination: destination)
        }
    }

    static func payloadString(for mappings: [HIDKeyboardModifierMapping]) -> String? {
        let payload = HIDKeyboardModifierMappingPayload(userKeyMapping: mappings)
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

final class CapsLockHyperRemapper {
    private var originalMappings: [HIDKeyboardModifierMapping]?
    private var isApplied = false

    func apply() -> Bool {
        if isApplied { return true }
        guard let currentMappings = readMappings(),
              writeMappings(CapsLockHyperMapping.applying(to: currentMappings))
        else { return false }
        originalMappings = currentMappings
        isApplied = true
        return true
    }

    func restore() {
        guard isApplied else { return }
        let currentMappings = readMappings() ?? []
        let originalMappings = originalMappings ?? []
        _ = writeMappings(CapsLockHyperMapping.restoring(current: currentMappings, original: originalMappings))
        self.originalMappings = nil
        isApplied = false
    }

    private func readMappings() -> [HIDKeyboardModifierMapping]? {
        guard let data = try? runHidutil(arguments: ["property", "--get", "UserKeyMapping"]) else {
            return nil
        }
        return CapsLockHyperMapping.parseMappings(from: data)
    }

    private func writeMappings(_ mappings: [HIDKeyboardModifierMapping]) -> Bool {
        guard let payload = CapsLockHyperMapping.payloadString(for: mappings) else { return false }
        return (try? runHidutil(arguments: ["property", "--set", payload])) != nil
    }

    private func runHidutil(arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            throw CocoaError(.executableLoad)
        }
        return data
    }
}
