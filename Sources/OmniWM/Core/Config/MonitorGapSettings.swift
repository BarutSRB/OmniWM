// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct MonitorGapSettings: MonitorSettingsType {
    let id: UUID
    var monitorName: String
    var monitorDisplayId: CGDirectDisplayID?

    var outerGapLeft: Double?
    var outerGapRight: Double?
    var outerGapTop: Double?
    var outerGapBottom: Double?

    init(
        id: UUID = UUID(),
        monitorName: String,
        monitorDisplayId: CGDirectDisplayID? = nil,
        outerGapLeft: Double? = nil,
        outerGapRight: Double? = nil,
        outerGapTop: Double? = nil,
        outerGapBottom: Double? = nil
    ) {
        self.id = id
        self.monitorName = monitorName
        self.monitorDisplayId = monitorDisplayId
        self.outerGapLeft = outerGapLeft
        self.outerGapRight = outerGapRight
        self.outerGapTop = outerGapTop
        self.outerGapBottom = outerGapBottom
    }

    private enum CodingKeys: String, CodingKey {
        case id, monitorName, monitorDisplayId
        case outerGapLeft, outerGapRight, outerGapTop, outerGapBottom
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        monitorName = try container.decode(String.self, forKey: .monitorName)
        monitorDisplayId = try container.decodeIfPresent(CGDirectDisplayID.self, forKey: .monitorDisplayId)
        outerGapLeft = try container.decodeIfPresent(Double.self, forKey: .outerGapLeft)
        outerGapRight = try container.decodeIfPresent(Double.self, forKey: .outerGapRight)
        outerGapTop = try container.decodeIfPresent(Double.self, forKey: .outerGapTop)
        outerGapBottom = try container.decodeIfPresent(Double.self, forKey: .outerGapBottom)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(monitorName, forKey: .monitorName)
        try container.encodeIfPresent(monitorDisplayId, forKey: .monitorDisplayId)
        try container.encodeIfPresent(outerGapLeft, forKey: .outerGapLeft)
        try container.encodeIfPresent(outerGapRight, forKey: .outerGapRight)
        try container.encodeIfPresent(outerGapTop, forKey: .outerGapTop)
        try container.encodeIfPresent(outerGapBottom, forKey: .outerGapBottom)
    }
}

struct ResolvedGapSettings: Equatable {
    let outerGapLeft: CGFloat
    let outerGapRight: CGFloat
    let outerGapTop: CGFloat
    let outerGapBottom: CGFloat
}
