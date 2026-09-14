// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

@MainActor
struct SettingsFileWriteTransaction {
    struct Failure {
        let error: any Error
        let notice: SettingsConfigNotice?
        let diagnostic: String?
    }

    enum Outcome {
        case saved(SettingsConfigNotice?)
        case failed(Failure)
    }

    struct MigrationFailure {
        let error: any Error
        let backupURL: URL?
        let reason: String

        func notice(for migration: SettingsMigrationReport) -> SettingsConfigNotice {
            .migrationWriteBlocked(report: migration, backupURL: backupURL, reason: reason)
        }
    }

    enum MigrationOutcome {
        case migrated(SettingsConfigNotice)
        case blocked(MigrationFailure)
    }

    private struct PreparedMigration {
        let data: Data
        let backupURL: URL
    }

    private enum ExistingSettings {
        case absent
        case decoded(data: Data, result: SettingsTOMLDecodeResult)
        case invalid(data: Data, reason: String)

        var data: Data? {
            switch self {
            case .absent:
                nil
            case let .decoded(data, _),
                 let .invalid(data, _):
                data
            }
        }
    }

    private let directoryURL: URL
    private let fileURL: URL
    private let targetURL: URL

    init(directoryURL: URL, fileURL: URL, targetURL: URL) {
        self.directoryURL = directoryURL
        self.fileURL = fileURL
        self.targetURL = targetURL
    }

    func perform(_ export: SettingsExport, persist: (Data) throws -> Void) -> Outcome {
        let existing: ExistingSettings
        do {
            existing = try inspectExistingSettings()
        } catch let error as SettingsTOMLCodecError {
            guard case let .unsupportedSchemaVersion(found, supported) = error else {
                return .failed(Failure(error: error, notice: nil, diagnostic: nil))
            }
            return .failed(Failure(
                error: error,
                notice: .unsupportedVersion(found: found, supported: supported),
                diagnostic: "Refusing to overwrite unsupported settings at \(fileURL.path): \(error.localizedDescription)"
            ))
        } catch {
            return .failed(Failure(error: error, notice: nil, diagnostic: nil))
        }
        if case let .decoded(data, result) = existing, let migration = result.migration {
            switch executeMigration(
                originalData: data,
                decoded: result,
                export: export,
                migration: migration,
                persist: persist
            ) {
            case let .migrated(notice):
                return .saved(notice)
            case let .blocked(failure):
                return .failed(Failure(
                    error: failure.error,
                    notice: failure.notice(for: migration),
                    diagnostic: "Failed to preserve and upgrade \(fileURL.path); writes are blocked: \(failure.reason)"
                ))
            }
        }
        return preserveAndPersist(export, over: existing, persist: persist)
    }

    private func inspectExistingSettings() throws -> ExistingSettings {
        guard let data = try SettingsFileAccess.existingData(at: targetURL) else { return .absent }
        do {
            return .decoded(data: data, result: try SettingsTOMLCodec.decodeForLoad(data))
        } catch let error as SettingsTOMLCodecError {
            if case .unsupportedSchemaVersion = error { throw error }
            return .invalid(data: data, reason: SettingsTOMLCodec.diagnosticDescription(for: error))
        } catch {
            return .invalid(data: data, reason: SettingsTOMLCodec.diagnosticDescription(for: error))
        }
    }

    func executeMigration(
        originalData: Data,
        decoded: SettingsTOMLDecodeResult,
        export: SettingsExport,
        migration: SettingsMigrationReport,
        persist: (Data) throws -> Void
    ) -> MigrationOutcome {
        var backupURL: URL?
        do {
            let rewrite = try prepareMigrationRewrite(
                originalData: originalData,
                decoded: decoded,
                export: export,
                migration: migration
            )
            backupURL = rewrite.backupURL
            try persist(rewrite.data)
            reportMigration(migration, backupURL: rewrite.backupURL)
            return .migrated(.migrated(report: migration, backupURL: rewrite.backupURL))
        } catch {
            let reason = SettingsTOMLCodec.diagnosticDescription(for: error)
            return .blocked(MigrationFailure(error: error, backupURL: backupURL, reason: reason))
        }
    }

    private func preserveAndPersist(
        _ export: SettingsExport,
        over existing: ExistingSettings,
        persist: (Data) throws -> Void
    ) -> Outcome {
        do {
            let data = try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: existing.data)
            try persist(data)
            return .saved(nil)
        } catch let error as SettingsTOMLCodecError {
            switch error {
            case .cannotSafelyPreservePreviousData:
                guard case let .invalid(data, reason) = existing else {
                    return blockUnsafePreservation(error)
                }
                return recoverInvalidDuringSave(data, reason: reason, export: export, persist: persist)
            case .cannotSafelyPreserveArrayElement:
                return blockUnsafePreservation(error)
            case .invalidSchemaVersion,
                 .unsupportedSchemaVersion,
                 .migrationInvariant:
                return .failed(Failure(error: error, notice: nil, diagnostic: nil))
            }
        } catch {
            return .failed(Failure(error: error, notice: nil, diagnostic: nil))
        }
    }

    private func blockUnsafePreservation(_ error: SettingsTOMLCodecError) -> Outcome {
        let reason = error.localizedDescription
        return .failed(Failure(
            error: error,
            notice: .persistenceWriteBlocked(reason: reason),
            diagnostic: "Refusing to overwrite \(fileURL.path); writes are blocked: \(reason)"
        ))
    }

    private func recoverInvalidDuringSave(
        _ invalidData: Data,
        reason: String,
        export: SettingsExport,
        persist: (Data) throws -> Void
    ) -> Outcome {
        do {
            let backupURL = try recoverInvalidSettings(invalidData, replacingWith: export, persist: persist)
            Log.config.error("Recovered invalid settings from \(fileURL.path) to \(backupURL.path): \(reason)")
            return .saved(.recoveredInvalid(backupURL: backupURL, reason: reason))
        } catch {
            let recoveryReason = SettingsTOMLCodec.diagnosticDescription(for: error)
            let combinedReason = "\(reason) Recovery failed: \(recoveryReason)"
            return .failed(Failure(
                error: error,
                notice: .persistenceWriteBlocked(reason: combinedReason),
                diagnostic: "Failed to recover invalid settings at \(fileURL.path): \(combinedReason)"
            ))
        }
    }

    private func prepareMigrationRewrite(
        originalData: Data,
        decoded: SettingsTOMLDecodeResult,
        export: SettingsExport,
        migration: SettingsMigrationReport
    ) throws -> PreparedMigration {
        guard let migratedData = decoded.migratedData else {
            throw SettingsTOMLCodecError.migrationInvariant(
                "Settings migration to schema version \(migration.toVersion) did not produce TOML data."
            )
        }
        let data = try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: migratedData)
        let backupURL = try SettingsFileAccess.secureBackup(
            originalData,
            in: directoryURL,
            fileNames: SettingsFilePersistence.migrationBackupFileNames(for: migration.toVersion),
            exhaustedError: .migrationBackupSlotsExhausted(targetVersion: migration.toVersion)
        )
        return PreparedMigration(data: data, backupURL: backupURL)
    }

    @discardableResult
    private func recoverInvalidSettings(
        _ invalidData: Data,
        replacingWith export: SettingsExport,
        persist: (Data) throws -> Void
    ) throws -> URL {
        let backupURL = try SettingsFileAccess.secureBackup(
            invalidData,
            in: directoryURL,
            fileNames: SettingsFilePersistence.corruptFileNames,
            exhaustedError: .corruptBackupSlotsExhausted
        )
        let replacement = try SettingsTOMLCodec.encode(export)
        try persist(replacement)
        return backupURL
    }

    private func reportMigration(_ migration: SettingsMigrationReport, backupURL: URL) {
        let diagnostic = "Migrated \(fileURL.path) from schema version \(migration.fromVersion) "
            + "to \(migration.toVersion); exact backup: \(backupURL.path)"
        Log.config.notice(diagnostic)
        for message in migration.messages {
            let diagnostic = "Settings migration: \(message)"
            Log.config.notice(diagnostic)
        }
    }
}
