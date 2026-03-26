import AppKit
import SwiftUI

enum ConfigFileAction {
    case create
    case export(SettingsExportMode)
    case `import`
    case reveal
    case open

    var failureAlertTitle: String {
        switch self {
        case .create:
            "Could Not Create Config File"
        case .export:
            "Could Not Export Settings"
        case .import:
            "Could Not Import Settings"
        case .reveal:
            "Could Not Reveal Settings File"
        case .open:
            "Could Not Open Settings File"
        }
    }
}

@MainActor
enum ConfigFileWorkflow {
    static func perform(
        _ action: ConfigFileAction,
        targetURL: URL = SettingsStore.exportURL,
        settings: SettingsStore,
        controller: WMController,
        openFile: (URL) -> Bool = { NSWorkspace.shared.open($0) },
        revealFile: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    ) throws -> ExportStatus {
        switch action {
        case .create:
            try settings.exportSettings(to: targetURL, mode: .full)
            return .created
        case .export(let mode):
            try settings.exportSettings(to: targetURL, mode: mode)
            return .exported(mode)
        case .import:
            try settings.importSettings(from: targetURL, applyingTo: controller)
            return .imported
        case .reveal:
            if !settings.settingsFileExists(at: targetURL) {
                _ = try perform(
                    .create,
                    targetURL: targetURL,
                    settings: settings,
                    controller: controller,
                    openFile: openFile,
                    revealFile: revealFile
                )
            }
            revealFile([targetURL])
            return .revealed
        case .open:
            if !settings.settingsFileExists(at: targetURL) {
                _ = try perform(
                    .create,
                    targetURL: targetURL,
                    settings: settings,
                    controller: controller,
                    openFile: openFile,
                    revealFile: revealFile
                )
            }
            guard openFile(targetURL) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return .opened
        }
    }
}

enum ExportStatus: Equatable {
    case exported(SettingsExportMode)
    case imported
    case created
    case revealed
    case opened
    case error(String)

    var message: String {
        switch self {
        case .exported(.full): "Editable config exported"
        case .exported(.compact): "Compact backup exported"
        case .imported: "Settings imported"
        case .created: "Settings file created"
        case .revealed: "Settings file revealed in Finder"
        case .opened: "Settings file opened"
        case .error(let msg): "Error: \(msg)"
        }
    }

    var successAlertTitle: String? {
        switch self {
        case .exported(.full): "Editable Config Exported"
        case .exported(.compact): "Compact Backup Exported"
        case .imported: "Settings Imported"
        case .created: "Settings File Created"
        case .revealed: "Settings File Revealed"
        case .opened: "Settings File Opened"
        case .error: nil
        }
    }

    var icon: String {
        switch self {
        case .exported, .imported, .created, .revealed, .opened: "checkmark.circle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .exported, .imported, .created, .revealed, .opened: .green
        case .error: .red
        }
    }
}
