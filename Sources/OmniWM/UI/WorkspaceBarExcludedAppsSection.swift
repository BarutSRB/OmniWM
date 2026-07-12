// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

@MainActor
enum WorkspaceBarExcludedAppsEdits {
    @discardableResult
    static func setExcluded(
        _ excluded: Bool,
        bundleID: String,
        settings: SettingsStore,
        refresh: () -> Void
    ) -> Bool {
        let changed = excluded
            ? settings.addWorkspaceBarExcludedBundleID(bundleID)
            : settings.removeWorkspaceBarExcludedBundleID(bundleID)
        guard changed else { return false }
        refresh()
        return true
    }
}

struct WorkspaceBarExcludedAppsSection: View {
    @Bindable var settings: SettingsStore
    let controller: WMController

    @State private var newBundleID = ""

    private var candidates: [WorkspaceBarExcludedAppCandidate] {
        var candidatesByID: [String: WorkspaceBarExcludedAppCandidate] = [:]

        for entry in controller.workspaceManager.allEntries() {
            let appInfo = controller.appInfoCache.info(for: entry.pid)
            guard let bundleID = normalizedBundleID(
                entry.managedReplacementMetadata?.bundleId ?? appInfo?.bundleId
            ) else { continue }

            let key = bundleID.lowercased()
            if var existing = candidatesByID[key] {
                existing.name = existing.name ?? appInfo?.name
                existing.icon = existing.icon ?? appInfo?.icon
                existing.isManaged = true
                candidatesByID[key] = existing
            } else {
                candidatesByID[key] = WorkspaceBarExcludedAppCandidate(
                    bundleID: bundleID,
                    name: appInfo?.name,
                    icon: appInfo?.icon,
                    isManaged: true
                )
            }
        }

        for configuredBundleID in settings.workspaceBarExcludedBundleIDs {
            guard let bundleID = normalizedBundleID(configuredBundleID) else { continue }
            let key = bundleID.lowercased()
            if var existing = candidatesByID[key] {
                existing.bundleID = bundleID
                candidatesByID[key] = existing
            } else {
                candidatesByID[key] = WorkspaceBarExcludedAppCandidate(
                    bundleID: bundleID,
                    name: nil,
                    icon: nil,
                    isManaged: false
                )
            }
        }

        return candidatesByID.values.sorted(by: WorkspaceBarExcludedAppCandidate.sort)
    }

    var body: some View {
        Section("Excluded Apps — All Monitors") {
            SettingsCaption(
                "Excluded apps stay running and fully managed by OmniWM. Only their workspace-bar "
                    + "representation is removed on every monitor."
            )

            if candidates.isEmpty {
                SettingsCaption("No managed apps with bundle IDs are currently available.")
            } else {
                ForEach(candidates) { candidate in
                    Toggle(isOn: exclusionBinding(for: candidate.bundleID)) {
                        WorkspaceBarExcludedAppRow(candidate: candidate)
                    }
                }
            }

            HStack {
                TextField("Bundle ID", text: $newBundleID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addBundleID)

                Button("Add", action: addBundleID)
                    .disabled(!canAddBundleID)
            }
        }
    }

    private var canAddBundleID: Bool {
        guard let bundleID = normalizedBundleID(newBundleID) else { return false }
        return !settings.workspaceBarExcludedBundleIDs.contains {
            $0.caseInsensitiveCompare(bundleID) == .orderedSame
        }
    }

    private func exclusionBinding(for bundleID: String) -> Binding<Bool> {
        Binding(
            get: {
                settings.workspaceBarExcludedBundleIDs.contains {
                    $0.caseInsensitiveCompare(bundleID) == .orderedSame
                }
            },
            set: { excluded in
                WorkspaceBarExcludedAppsEdits.setExcluded(
                    excluded,
                    bundleID: bundleID,
                    settings: settings,
                    refresh: controller.requestWorkspaceBarRefresh
                )
            }
        )
    }

    private func addBundleID() {
        guard canAddBundleID,
              let bundleID = normalizedBundleID(newBundleID),
              WorkspaceBarExcludedAppsEdits.setExcluded(
                  true,
                  bundleID: bundleID,
                  settings: settings,
                  refresh: controller.requestWorkspaceBarRefresh
              )
        else {
            return
        }
        newBundleID = ""
    }

    private func normalizedBundleID(_ bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        let normalized = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

private struct WorkspaceBarExcludedAppCandidate: Identifiable {
    var bundleID: String
    var name: String?
    var icon: NSImage?
    var isManaged: Bool

    var id: String {
        bundleID.lowercased()
    }

    static func sort(
        _ lhs: WorkspaceBarExcludedAppCandidate,
        _ rhs: WorkspaceBarExcludedAppCandidate
    ) -> Bool {
        let lhsName = lhs.name ?? lhs.bundleID
        let rhsName = rhs.name ?? rhs.bundleID
        let nameOrder = lhsName.localizedCaseInsensitiveCompare(rhsName)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }

        let bundleIDOrder = lhs.bundleID.localizedCaseInsensitiveCompare(rhs.bundleID)
        if bundleIDOrder != .orderedSame {
            return bundleIDOrder == .orderedAscending
        }
        return lhs.bundleID < rhs.bundleID
    }
}

private struct WorkspaceBarExcludedAppRow: View {
    let candidate: WorkspaceBarExcludedAppCandidate

    var body: some View {
        HStack(spacing: 8) {
            if let icon = candidate.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name ?? candidate.bundleID)
                if candidate.name != nil {
                    Text(candidate.bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !candidate.isManaged {
                    Text("Not currently managed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
