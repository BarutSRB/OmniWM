import Foundation

enum ExternalCommandResult: Equatable, Sendable {
    case executed
    case ignoredDisabled
    case ignoredOverview
    case ignoredLayoutMismatch
    case staleWindowId
    case notFound
    case invalidArguments
}
