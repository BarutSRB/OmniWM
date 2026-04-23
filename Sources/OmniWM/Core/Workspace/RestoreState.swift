// SPDX-License-Identifier: GPL-2.0-only
import Foundation

@MainActor
final class RestoreState {
    let restorePlanner = RestorePlanner()
    let bootPersistedWindowRestoreCatalog: PersistedWindowRestoreCatalog

    var nativeFullscreenRecordsByOriginalToken: [WindowToken: WorkspaceManager.NativeFullscreenRecord] = [:]
    var nativeFullscreenOriginalTokenByCurrentToken: [WindowToken: WindowToken] = [:]
    var consumedBootPersistedWindowRestoreKeys: Set<PersistedWindowRestoreKey> = []
    var persistedWindowRestoreCatalogDirty = false
    var persistedWindowRestoreCatalogSaveScheduled = false

    init(settings: SettingsStore) {
        let raw = settings.loadPersistedWindowRestoreCatalog()
        // Older OmniWM builds persisted nil-title catch-all keys, which
        // matched any later admission whose metadata still had nil
        // title (AX facts not yet populated) and then consumed
        // themselves without doing useful work. Drop those on load so
        // the current session starts from a clean, titled-only catalog.
        // The next save (`buildPersistedWindowRestoreCatalog`) will
        // overwrite disk state with the same filter applied.
        let sanitizedEntries = raw.entries.filter { $0.key.isIdentifying }
        bootPersistedWindowRestoreCatalog = PersistedWindowRestoreCatalog(
            entries: sanitizedEntries
        )
    }
}
