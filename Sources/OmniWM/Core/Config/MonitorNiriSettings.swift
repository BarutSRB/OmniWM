import CoreGraphics
import Foundation

struct MonitorNiriSettings: MonitorSettingsType {
    let id: UUID
    var monitorName: String
    var monitorDisplayId: CGDirectDisplayID?

    var maxVisibleColumns: Int?
    var maxWindowsPerColumn: Int?
    var centerFocusedColumn: CenterFocusedColumn?
    var alwaysCenterSingleColumn: Bool?
    var singleWindowAspectRatio: SingleWindowAspectRatio?
    var infiniteLoop: Bool?

    init(
        id: UUID = UUID(),
        monitorName: String,
        monitorDisplayId: CGDirectDisplayID? = nil,
        maxVisibleColumns: Int? = nil,
        maxWindowsPerColumn: Int? = nil,
        centerFocusedColumn: CenterFocusedColumn? = nil,
        alwaysCenterSingleColumn: Bool? = nil,
        singleWindowAspectRatio: SingleWindowAspectRatio? = nil,
        infiniteLoop: Bool? = nil
    ) {
        self.id = id
        self.monitorName = monitorName
        self.monitorDisplayId = monitorDisplayId
        self.maxVisibleColumns = maxVisibleColumns
        self.maxWindowsPerColumn = maxWindowsPerColumn
        self.centerFocusedColumn = centerFocusedColumn
        self.alwaysCenterSingleColumn = alwaysCenterSingleColumn
        self.singleWindowAspectRatio = singleWindowAspectRatio
        self.infiniteLoop = infiniteLoop
    }

    private enum CodingKeys: String, CodingKey {
        case id, monitorName, monitorDisplayId, maxVisibleColumns, maxWindowsPerColumn
        case centerFocusedColumn, alwaysCenterSingleColumn, singleWindowAspectRatio, infiniteLoop
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        monitorName = try container.decode(String.self, forKey: .monitorName)
        monitorDisplayId = try container.decodeIfPresent(CGDirectDisplayID.self, forKey: .monitorDisplayId)
        maxVisibleColumns = try container.decodeIfPresent(Int.self, forKey: .maxVisibleColumns)
        maxWindowsPerColumn = try container.decodeIfPresent(Int.self, forKey: .maxWindowsPerColumn)
        centerFocusedColumn = try container.decodeIfPresent(String.self, forKey: .centerFocusedColumn)
            .flatMap { CenterFocusedColumn(rawValue: $0) }
        alwaysCenterSingleColumn = try container.decodeIfPresent(Bool.self, forKey: .alwaysCenterSingleColumn)
        singleWindowAspectRatio = try container.decodeIfPresent(String.self, forKey: .singleWindowAspectRatio)
            .flatMap { SingleWindowAspectRatio(rawValue: $0) }
        infiniteLoop = try container.decodeIfPresent(Bool.self, forKey: .infiniteLoop)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(monitorName, forKey: .monitorName)
        try container.encodeIfPresent(monitorDisplayId, forKey: .monitorDisplayId)
        try container.encodeIfPresent(maxVisibleColumns, forKey: .maxVisibleColumns)
        try container.encodeIfPresent(maxWindowsPerColumn, forKey: .maxWindowsPerColumn)
        try container.encodeIfPresent(centerFocusedColumn?.rawValue, forKey: .centerFocusedColumn)
        try container.encodeIfPresent(alwaysCenterSingleColumn, forKey: .alwaysCenterSingleColumn)
        try container.encodeIfPresent(singleWindowAspectRatio?.rawValue, forKey: .singleWindowAspectRatio)
        try container.encodeIfPresent(infiniteLoop, forKey: .infiniteLoop)
    }
}

struct ResolvedNiriSettings: Equatable {
    let maxVisibleColumns: Int
    let maxWindowsPerColumn: Int
    let centerFocusedColumn: CenterFocusedColumn
    let alwaysCenterSingleColumn: Bool
    let singleWindowAspectRatio: SingleWindowAspectRatio
    let infiniteLoop: Bool
}
