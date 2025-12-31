import Foundation

struct MonitorNiriSettings: Codable, Identifiable, Equatable {
    let id: UUID
    var monitorName: String

    var maxVisibleColumns: Int?
    var maxWindowsPerColumn: Int?
    var centerFocusedColumn: String?
    var alwaysCenterSingleColumn: Bool?
    var singleWindowAspectRatio: String?
    var infiniteLoop: Bool?

    init(
        id: UUID = UUID(),
        monitorName: String,
        maxVisibleColumns: Int? = nil,
        maxWindowsPerColumn: Int? = nil,
        centerFocusedColumn: String? = nil,
        alwaysCenterSingleColumn: Bool? = nil,
        singleWindowAspectRatio: String? = nil,
        infiniteLoop: Bool? = nil
    ) {
        self.id = id
        self.monitorName = monitorName
        self.maxVisibleColumns = maxVisibleColumns
        self.maxWindowsPerColumn = maxWindowsPerColumn
        self.centerFocusedColumn = centerFocusedColumn
        self.alwaysCenterSingleColumn = alwaysCenterSingleColumn
        self.singleWindowAspectRatio = singleWindowAspectRatio
        self.infiniteLoop = infiniteLoop
    }

    var isUsingAllGlobalDefaults: Bool {
        maxVisibleColumns == nil &&
            maxWindowsPerColumn == nil &&
            centerFocusedColumn == nil &&
            alwaysCenterSingleColumn == nil &&
            singleWindowAspectRatio == nil &&
            infiniteLoop == nil
    }

    mutating func resetToGlobalDefaults() {
        maxVisibleColumns = nil
        maxWindowsPerColumn = nil
        centerFocusedColumn = nil
        alwaysCenterSingleColumn = nil
        singleWindowAspectRatio = nil
        infiniteLoop = nil
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
