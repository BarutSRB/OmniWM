import Foundation

enum SettingsMigration {
    struct Patches: OptionSet {
        let rawValue: Int
    }

    private static let patchesKey = "appliedSettingsPatches"

    static func run(defaults: UserDefaults = .standard) {
        let applied = Patches(rawValue: defaults.integer(forKey: patchesKey))
        _ = applied
    }

    private static func runPatch(
        _ patch: Patches,
        applied: Patches,
        defaults: UserDefaults,
        action: () -> Void
    ) {
        guard !applied.contains(patch) else { return }
        action()
        let newApplied = applied.union(patch)
        defaults.set(newApplied.rawValue, forKey: patchesKey)
    }
}
