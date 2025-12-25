import Foundation

struct AppRule: Codable, Identifiable, Equatable {
    let id: UUID
    var bundleId: String
    var alwaysFloat: Bool?
    var assignToWorkspace: String?
    var minWidth: Double?
    var minHeight: Double?

    init(
        id: UUID = UUID(),
        bundleId: String,
        alwaysFloat: Bool? = nil,
        assignToWorkspace: String? = nil,
        minWidth: Double? = nil,
        minHeight: Double? = nil
    ) {
        self.id = id
        self.bundleId = bundleId
        self.alwaysFloat = alwaysFloat
        self.assignToWorkspace = assignToWorkspace
        self.minWidth = minWidth
        self.minHeight = minHeight
    }

    var hasAnyRule: Bool {
        alwaysFloat != nil || assignToWorkspace != nil ||
            minWidth != nil || minHeight != nil
    }
}
