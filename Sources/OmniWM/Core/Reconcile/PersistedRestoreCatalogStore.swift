// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct RestoreCatalogBuildSnapshot: Sendable {
    let entries: [PersistedWindowRestoreCatalogBuildEntry]
}

struct PersistedWindowRestoreCatalogBuildEntry: Sendable {
    let token: WindowToken
    let metadata: ManagedReplacementMetadata
    let workspaceName: String
    let topologyProfile: TopologyProfile
    let preferredMonitor: DisplayFingerprint?
    let floatingFrame: CGRect?
    let normalizedFloatingOrigin: CGPoint?
    let restoreToFloating: Bool
    let rescueEligible: Bool
    let niriPlacement: PersistedNiriPlacement?
    let detachedNiriContainerSizingState: NiriContainerSizingState?
    let dwindlePlacement: PersistedDwindlePlacement?

    func persistedEntry() -> PersistedWindowRestoreEntry? {
        guard let key = PersistedWindowRestoreKey(metadata: metadata) else { return nil }
        return PersistedWindowRestoreEntry(
            key: key,
            identity: PersistedWindowRestoreIdentity(
                token: token,
                metadata: metadata
            ),
            restoreIntent: PersistedRestoreIntent(
                workspaceName: workspaceName,
                topologyProfile: topologyProfile,
                preferredMonitor: preferredMonitor,
                floatingFrame: floatingFrame,
                normalizedFloatingOrigin: normalizedFloatingOrigin,
                restoreToFloating: restoreToFloating,
                rescueEligible: rescueEligible,
                niriPlacement: niriPlacement,
                detachedNiriContainerSizingState: detachedNiriContainerSizingState,
                dwindlePlacement: dwindlePlacement
            )
        )
    }
}

enum PersistedWindowRestoreCatalogBuilder {
    static func build(from snapshot: RestoreCatalogBuildSnapshot) -> PersistedWindowRestoreCatalog {
        var candidatesByBaseKey: [PersistedWindowRestoreBaseKey: [PersistedWindowRestoreEntry]] = [:]

        for snapshotEntry in snapshot.entries {
            guard let entry = snapshotEntry.persistedEntry() else { continue }
            candidatesByBaseKey[entry.key.baseKey, default: []].append(entry)
        }

        var persistedEntries: [PersistedWindowRestoreEntry] = []
        persistedEntries.reserveCapacity(candidatesByBaseKey.count)

        for candidates in candidatesByBaseKey.values {
            if candidates.count == 1, let candidate = candidates.first {
                persistedEntries.append(candidate)
                continue
            }

            let identityCandidates = candidates.filter { $0.identity != nil }
            persistedEntries.append(contentsOf: identityCandidates)

            let semanticCandidates = candidates.filter { $0.identity == nil }
            let candidatesByTitle = Dictionary(grouping: semanticCandidates, by: { $0.key.title })
            for (title, titledCandidates) in candidatesByTitle where title != nil && titledCandidates.count == 1 {
                if let candidate = titledCandidates.first {
                    persistedEntries.append(candidate)
                }
            }
        }

        persistedEntries.sort { lhs, rhs in
            let lhsWorkspace = lhs.restoreIntent.workspaceName
            let rhsWorkspace = rhs.restoreIntent.workspaceName
            if lhsWorkspace != rhsWorkspace {
                return lhsWorkspace < rhsWorkspace
            }
            if lhs.key.baseKey.bundleId != rhs.key.baseKey.bundleId {
                return lhs.key.baseKey.bundleId < rhs.key.baseKey.bundleId
            }
            if (lhs.key.title ?? "") != (rhs.key.title ?? "") {
                return (lhs.key.title ?? "") < (rhs.key.title ?? "")
            }
            if lhs.identity?.pid != rhs.identity?.pid {
                return (lhs.identity?.pid ?? Int32.min) < (rhs.identity?.pid ?? Int32.min)
            }
            return (lhs.identity?.windowId ?? Int.min) < (rhs.identity?.windowId ?? Int.min)
        }

        return PersistedWindowRestoreCatalog(entries: persistedEntries)
    }
}

@MainActor
final class PersistedRestoreCatalogStore {
    let bootCatalog: PersistedWindowRestoreCatalog
    private(set) var consumedBootEntries: Set<PersistedWindowRestoreConsumptionKey> = []

    private var dirty = false
    private var saveScheduled = false
    private var buildInFlight = false
    private var revision: UInt64 = 0
    private let buildSnapshot: @MainActor () -> RestoreCatalogBuildSnapshot
    private let save: @MainActor (PersistedWindowRestoreCatalog) -> Void

    init(
        bootCatalog: PersistedWindowRestoreCatalog,
        buildSnapshot: @escaping @MainActor () -> RestoreCatalogBuildSnapshot,
        save: @escaping @MainActor (PersistedWindowRestoreCatalog) -> Void
    ) {
        self.bootCatalog = bootCatalog
        self.buildSnapshot = buildSnapshot
        self.save = save
    }

    func noteConsumed(_ key: PersistedWindowRestoreConsumptionKey) {
        consumedBootEntries.insert(key)
    }

    func scheduleSave() {
        markDirty()
        enqueueSave()
    }

    func flushNow() {
        markDirty()
        dirty = false
        save(PersistedWindowRestoreCatalogBuilder.build(from: buildSnapshot()))
    }

    private func markDirty() {
        dirty = true
        revision &+= 1
    }

    private func enqueueSave() {
        guard !saveScheduled, !buildInFlight else { return }
        saveScheduled = true

        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 75_000_000)
            } catch {
                return
            }
            guard let self else { return }
            self.saveScheduled = false
            self.startBuildIfNeeded()
        }
    }

    private func startBuildIfNeeded() {
        guard dirty else { return }
        dirty = false
        buildInFlight = true
        let revision = revision
        let snapshot = buildSnapshot()

        Task { [weak self] in
            let catalog = await Task.detached(priority: .utility) {
                PersistedWindowRestoreCatalogBuilder.build(from: snapshot)
            }.value
            self?.completeBuild(catalog, revision: revision)
        }
    }

    private func completeBuild(_ catalog: PersistedWindowRestoreCatalog, revision: UInt64) {
        buildInFlight = false
        if revision == self.revision, !dirty {
            save(catalog)
            return
        }
        if dirty {
            enqueueSave()
        }
    }
}
