// SPDX-License-Identifier: GPL-2.0-only
import Foundation

enum ExternalCommandResult: Equatable, Sendable, Error {
    case executed
    case ignoredDisabled
    case ignoredOverview
    case ignoredLayoutMismatch
    case staleWindowId
    case notFound
    case invalidArguments
}
