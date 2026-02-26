import Foundation
import CoreGraphics

struct MonitorDwindleSettings: MonitorSettingsType {
    let id: UUID
    var monitorName: String
    var monitorDisplayId: CGDirectDisplayID?

    var smartSplit: Bool?
    var defaultSplitRatio: Double?
    var splitWidthMultiplier: Double?
    var singleWindowAspectRatio: DwindleSingleWindowAspectRatio?
    var useGlobalGaps: Bool?
    var innerGap: Double?
    var outerGapTop: Double?
    var outerGapBottom: Double?
    var outerGapLeft: Double?
    var outerGapRight: Double?

    init(
        id: UUID = UUID(),
        monitorName: String,
        monitorDisplayId: CGDirectDisplayID? = nil,
        smartSplit: Bool? = nil,
        defaultSplitRatio: Double? = nil,
        splitWidthMultiplier: Double? = nil,
        singleWindowAspectRatio: DwindleSingleWindowAspectRatio? = nil,
        useGlobalGaps: Bool? = nil,
        innerGap: Double? = nil,
        outerGapTop: Double? = nil,
        outerGapBottom: Double? = nil,
        outerGapLeft: Double? = nil,
        outerGapRight: Double? = nil
    ) {
        self.id = id
        self.monitorName = monitorName
        self.monitorDisplayId = monitorDisplayId
        self.smartSplit = smartSplit
        self.defaultSplitRatio = defaultSplitRatio
        self.splitWidthMultiplier = splitWidthMultiplier
        self.singleWindowAspectRatio = singleWindowAspectRatio
        self.useGlobalGaps = useGlobalGaps
        self.innerGap = innerGap
        self.outerGapTop = outerGapTop
        self.outerGapBottom = outerGapBottom
        self.outerGapLeft = outerGapLeft
        self.outerGapRight = outerGapRight
    }

    private enum CodingKeys: String, CodingKey {
        case id, monitorName, monitorDisplayId, smartSplit, defaultSplitRatio, splitWidthMultiplier
        case singleWindowAspectRatio, useGlobalGaps, innerGap
        case outerGapTop, outerGapBottom, outerGapLeft, outerGapRight
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        monitorName = try container.decode(String.self, forKey: .monitorName)
        monitorDisplayId = try container.decodeIfPresent(CGDirectDisplayID.self, forKey: .monitorDisplayId)
        smartSplit = try container.decodeIfPresent(Bool.self, forKey: .smartSplit)
        defaultSplitRatio = try container.decodeIfPresent(Double.self, forKey: .defaultSplitRatio)
        splitWidthMultiplier = try container.decodeIfPresent(Double.self, forKey: .splitWidthMultiplier)
        singleWindowAspectRatio = try container.decodeIfPresent(String.self, forKey: .singleWindowAspectRatio)
            .flatMap { DwindleSingleWindowAspectRatio(rawValue: $0) }
        useGlobalGaps = try container.decodeIfPresent(Bool.self, forKey: .useGlobalGaps)
        innerGap = try container.decodeIfPresent(Double.self, forKey: .innerGap)
        outerGapTop = try container.decodeIfPresent(Double.self, forKey: .outerGapTop)
        outerGapBottom = try container.decodeIfPresent(Double.self, forKey: .outerGapBottom)
        outerGapLeft = try container.decodeIfPresent(Double.self, forKey: .outerGapLeft)
        outerGapRight = try container.decodeIfPresent(Double.self, forKey: .outerGapRight)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(monitorName, forKey: .monitorName)
        try container.encodeIfPresent(monitorDisplayId, forKey: .monitorDisplayId)
        try container.encodeIfPresent(smartSplit, forKey: .smartSplit)
        try container.encodeIfPresent(defaultSplitRatio, forKey: .defaultSplitRatio)
        try container.encodeIfPresent(splitWidthMultiplier, forKey: .splitWidthMultiplier)
        try container.encodeIfPresent(singleWindowAspectRatio?.rawValue, forKey: .singleWindowAspectRatio)
        try container.encodeIfPresent(useGlobalGaps, forKey: .useGlobalGaps)
        try container.encodeIfPresent(innerGap, forKey: .innerGap)
        try container.encodeIfPresent(outerGapTop, forKey: .outerGapTop)
        try container.encodeIfPresent(outerGapBottom, forKey: .outerGapBottom)
        try container.encodeIfPresent(outerGapLeft, forKey: .outerGapLeft)
        try container.encodeIfPresent(outerGapRight, forKey: .outerGapRight)
    }
}

struct ResolvedDwindleSettings: Equatable {
    let smartSplit: Bool
    let defaultSplitRatio: CGFloat
    let splitWidthMultiplier: CGFloat
    let singleWindowAspectRatio: DwindleSingleWindowAspectRatio
    let useGlobalGaps: Bool
    let innerGap: CGFloat
    let outerGapTop: CGFloat
    let outerGapBottom: CGFloat
    let outerGapLeft: CGFloat
    let outerGapRight: CGFloat
}
