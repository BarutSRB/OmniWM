// SPDX-License-Identifier: GPL-2.0-only
import COmniWMKernels
import CoreGraphics
import Foundation

struct RestorePlanner {
    struct EventInput {
        let event: WMEvent
        let snapshot: ReconcileSnapshot
        let monitors: [Monitor]
    }

    struct EventPlan: Equatable {
        var refreshRestoreIntents: Bool = false
        var interactionMonitorId: Monitor.ID? = nil
        var previousInteractionMonitorId: Monitor.ID? = nil
        var notes: [String] = []
    }

    struct PersistedHydrationInput {
        let metadata: ManagedReplacementMetadata
        let catalog: PersistedWindowRestoreCatalog
        let consumedKeys: Set<PersistedWindowRestoreKey>
        let monitors: [Monitor]
        let workspaceIdForName: (String) -> WorkspaceDescriptor.ID?
    }

    struct PersistedHydrationPlan: Equatable {
        let persistedEntry: PersistedWindowRestoreEntry
        let workspaceId: WorkspaceDescriptor.ID
        let preferredMonitorId: Monitor.ID?
        let targetMode: TrackedWindowMode
        let floatingFrame: CGRect?
        let consumedKey: PersistedWindowRestoreKey
    }

    struct FloatingFrameInput {
        let floatingFrame: CGRect
        let normalizedOrigin: CGPoint?
        let referenceMonitorId: Monitor.ID?
        let targetMonitor: Monitor?
    }

    struct FloatingRescueCandidate: Equatable {
        let token: WindowToken
        let pid: pid_t
        let windowId: Int
        let workspaceId: WorkspaceDescriptor.ID
        let targetMonitor: Monitor
        let currentFrame: CGRect?
        let floatingFrame: CGRect
        let normalizedOrigin: CGPoint?
        let referenceMonitorId: Monitor.ID?
        let isScratchpadHidden: Bool
        let isWorkspaceInactiveHidden: Bool
    }

    struct FloatingRescueOperation: Equatable {
        let token: WindowToken
        let pid: pid_t
        let windowId: Int
        let workspaceId: WorkspaceDescriptor.ID
        let targetMonitor: Monitor
        let targetFrame: CGRect
    }

    struct FloatingRescuePlan: Equatable {
        var operations: [FloatingRescueOperation] = []

        var rescuedCount: Int {
            operations.count
        }
    }

    func planEvent(_ input: EventInput) -> EventPlan {
        let sortedMonitors = Monitor.sortedByPosition(input.monitors)
        let rawMonitorIds = ContiguousArray(sortedMonitors.map { $0.displayId })
        var rawOutput = omniwm_restore_event_output()

        let status = rawMonitorIds.withUnsafeBufferPointer { monitorBuffer in
            var rawInput = omniwm_restore_event_input(
                event_kind: rawEventKind(input.event),
                sorted_monitor_ids: monitorBuffer.baseAddress,
                sorted_monitor_count: monitorBuffer.count,
                interaction_monitor_id: rawMonitorId(input.snapshot.interactionMonitorId),
                previous_interaction_monitor_id: rawMonitorId(input.snapshot.previousInteractionMonitorId),
                has_interaction_monitor_id: input.snapshot.interactionMonitorId == nil ? 0 : 1,
                has_previous_interaction_monitor_id: input.snapshot.previousInteractionMonitorId == nil ? 0 : 1
            )

            return omniwm_restore_plan_event(&rawInput, &rawOutput)
        }

        guard status == OMNIWM_KERNELS_STATUS_OK else {
            return EventPlan(
                refreshRestoreIntents: false,
                interactionMonitorId: input.snapshot.interactionMonitorId,
                previousInteractionMonitorId: input.snapshot.previousInteractionMonitorId,
                notes: []
            )
        }

        return EventPlan(
            refreshRestoreIntents: rawOutput.refresh_restore_intents != 0,
            interactionMonitorId: rawOutput.has_interaction_monitor_id != 0
                ? Monitor.ID(displayId: rawOutput.interaction_monitor_id)
                : nil,
            previousInteractionMonitorId: rawOutput.has_previous_interaction_monitor_id != 0
                ? Monitor.ID(displayId: rawOutput.previous_interaction_monitor_id)
                : nil,
            notes: notes(forEventNoteCode: rawOutput.note_code)
        )
    }

    func planPersistedHydration(_ input: PersistedHydrationInput) -> PersistedHydrationPlan? {
        guard let metadataKey = PersistedWindowRestoreKey(metadata: input.metadata) else {
            return nil
        }

        var stringTable = KernelStringTable()
        let rawMonitors = ContiguousArray(
            input.monitors.map { makeMonitorContext(for: $0, strings: &stringTable) }
        )
        var preferredMonitorPenalties = ContiguousArray<UInt8>()
        preferredMonitorPenalties.reserveCapacity(input.catalog.entries.count * input.monitors.count)

        var rawEntries = ContiguousArray<omniwm_restore_persisted_entry_snapshot>()
        rawEntries.reserveCapacity(input.catalog.entries.count)
        for entry in input.catalog.entries {
            let preferredPenaltyOffset = preferredMonitorPenalties.count
            if let preferredMonitor = entry.restoreIntent.preferredMonitor {
                for monitor in input.monitors {
                    preferredMonitorPenalties.append(namePenalty(lhs: preferredMonitor.name, rhs: monitor.name))
                }
            } else {
                preferredMonitorPenalties.append(contentsOf: repeatElement(UInt8.zero, count: input.monitors.count))
            }

            let resolvedWorkspaceId = input.workspaceIdForName(entry.restoreIntent.workspaceName)
            rawEntries.append(
                omniwm_restore_persisted_entry_snapshot(
                    key: makePersistedKey(for: entry.key, strings: &stringTable),
                    workspace_id: encode(optionalUUID: resolvedWorkspaceId),
                    preferred_monitor: makeMonitorKey(for: entry.restoreIntent.preferredMonitor, strings: &stringTable),
                    floating_frame: encode(rect: entry.restoreIntent.floatingFrame ?? .zero),
                    normalized_floating_origin: encode(point: entry.restoreIntent.normalizedFloatingOrigin ?? .zero),
                    preferred_monitor_name_penalty_offset: preferredPenaltyOffset,
                    restore_to_floating: entry.restoreIntent.restoreToFloating ? 1 : 0,
                    consumed: input.consumedKeys.contains(entry.key) ? 1 : 0,
                    has_workspace_id: resolvedWorkspaceId == nil ? 0 : 1,
                    has_preferred_monitor: entry.restoreIntent.preferredMonitor == nil ? 0 : 1,
                    has_floating_frame: entry.restoreIntent.floatingFrame == nil ? 0 : 1,
                    has_normalized_floating_origin: entry.restoreIntent.normalizedFloatingOrigin == nil ? 0 : 1
                )
            )
        }

        let rawMetadataKey = makePersistedKey(for: metadataKey, strings: &stringTable)
        var rawOutput = omniwm_restore_persisted_hydration_output()
        let status = stringTable.bytes.withUnsafeBufferPointer { stringBuffer in
            rawMonitors.withUnsafeBufferPointer { monitorBuffer in
                rawEntries.withUnsafeBufferPointer { entryBuffer in
                    preferredMonitorPenalties.withUnsafeBufferPointer { penaltyBuffer in
                        var rawInput = omniwm_restore_persisted_hydration_input(
                            metadata_key: rawMetadataKey,
                            metadata_mode: rawWindowMode(input.metadata.mode),
                            monitors: monitorBuffer.baseAddress,
                            monitor_count: monitorBuffer.count,
                            entries: entryBuffer.baseAddress,
                            entry_count: entryBuffer.count,
                            preferred_monitor_name_penalties: penaltyBuffer.baseAddress,
                            preferred_monitor_name_penalty_count: penaltyBuffer.count,
                            string_bytes: stringBuffer.baseAddress,
                            string_byte_count: stringBuffer.count
                        )

                        return omniwm_restore_plan_persisted_hydration(&rawInput, &rawOutput)
                    }
                }
            }
        }

        guard status == OMNIWM_KERNELS_STATUS_OK else {
            return nil
        }

        guard rawOutput.outcome == UInt32(OMNIWM_RESTORE_HYDRATION_OUTCOME_MATCHED) else {
            return nil
        }

        guard rawOutput.has_entry_index != 0,
              rawOutput.entry_index < input.catalog.entries.count
        else {
            return nil
        }

        let persistedEntry = input.catalog.entries[rawOutput.entry_index]
        return PersistedHydrationPlan(
            persistedEntry: persistedEntry,
            workspaceId: decode(uuid: rawOutput.workspace_id),
            preferredMonitorId: rawOutput.has_preferred_monitor_id != 0
                ? Monitor.ID(displayId: rawOutput.preferred_monitor_id)
                : nil,
            targetMode: trackedWindowMode(from: rawOutput.target_mode),
            floatingFrame: rawOutput.has_floating_frame != 0 ? decode(rect: rawOutput.floating_frame) : nil,
            consumedKey: persistedEntry.key
        )
    }

    func resolvedFloatingFrame(_ input: FloatingFrameInput) -> CGRect {
        var rawCandidate = makeFloatingRescueCandidate(
            token: nil,
            workspaceId: nil,
            targetMonitor: input.targetMonitor,
            floatingFrame: input.floatingFrame,
            normalizedOrigin: input.normalizedOrigin,
            referenceMonitorId: input.referenceMonitorId,
            currentFrame: nil,
            isScratchpadHidden: false,
            isWorkspaceInactiveHidden: false
        )
        var rawOperation = omniwm_restore_floating_rescue_operation(
            candidate_index: 0,
            target_frame: encode(rect: .zero)
        )
        let status: Int32 = withUnsafeMutablePointer(to: &rawOperation) { operationPointer in
            var rawOutput = omniwm_restore_floating_rescue_output(
                operations: operationPointer,
                operation_capacity: 1,
                operation_count: 0
            )

            let status = withUnsafePointer(to: &rawCandidate) { candidatePointer in
                omniwm_restore_plan_floating_rescue(candidatePointer, 1, &rawOutput)
            }

            guard rawOutput.operation_count == 1 else {
                return Int32(OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT)
            }
            return status
        }

        guard status == OMNIWM_KERNELS_STATUS_OK else {
            return input.floatingFrame
        }

        return decode(rect: rawOperation.target_frame)
    }

    func planFloatingRescue(_ candidates: [FloatingRescueCandidate]) -> FloatingRescuePlan {
        guard !candidates.isEmpty else {
            return FloatingRescuePlan()
        }

        var rawCandidates = ContiguousArray(
            candidates.map {
                makeFloatingRescueCandidate(
                    token: $0.token,
                    workspaceId: $0.workspaceId,
                    targetMonitor: $0.targetMonitor,
                    floatingFrame: $0.floatingFrame,
                    normalizedOrigin: $0.normalizedOrigin,
                    referenceMonitorId: $0.referenceMonitorId,
                    currentFrame: $0.currentFrame,
                    isScratchpadHidden: $0.isScratchpadHidden,
                    isWorkspaceInactiveHidden: $0.isWorkspaceInactiveHidden
                )
            }
        )
        var rawOperations = ContiguousArray(
            repeating: omniwm_restore_floating_rescue_operation(
                candidate_index: 0,
                target_frame: encode(rect: .zero)
            ),
            count: candidates.count
        )
        var rawOutput = omniwm_restore_floating_rescue_output(
            operations: nil,
            operation_capacity: rawOperations.count,
            operation_count: 0
        )

        let status = rawCandidates.withUnsafeMutableBufferPointer { candidateBuffer in
            rawOperations.withUnsafeMutableBufferPointer { operationBuffer in
                rawOutput.operations = operationBuffer.baseAddress
                return omniwm_restore_plan_floating_rescue(
                    candidateBuffer.baseAddress,
                    candidateBuffer.count,
                    &rawOutput
                )
            }
        }

        guard status == OMNIWM_KERNELS_STATUS_OK else {
            return FloatingRescuePlan()
        }

        let operations = rawOperations.prefix(rawOutput.operation_count).compactMap { operation -> FloatingRescueOperation? in
            guard operation.candidate_index < candidates.count else {
                return nil
            }
            let candidate = candidates[operation.candidate_index]
            return FloatingRescueOperation(
                token: candidate.token,
                pid: candidate.pid,
                windowId: candidate.windowId,
                workspaceId: candidate.workspaceId,
                targetMonitor: candidate.targetMonitor,
                targetFrame: decode(rect: operation.target_frame)
            )
        }

        return FloatingRescuePlan(operations: operations)
    }

    private func makeMonitorContext(
        for monitor: Monitor,
        strings: inout KernelStringTable
    ) -> omniwm_restore_monitor_context {
        omniwm_restore_monitor_context(
            frame_min_x: monitor.frame.minX,
            frame_max_y: monitor.frame.maxY,
            visible_frame: encode(rect: monitor.visibleFrame),
            key: makeMonitorKey(for: MonitorRestoreKey(monitor: monitor), strings: &strings)
        )
    }

    private func makeMonitorKey(
        for fingerprint: DisplayFingerprint?,
        strings: inout KernelStringTable
    ) -> omniwm_restore_monitor_key {
        guard let fingerprint else {
            return zeroMonitorKey()
        }

        let nameRef = strings.append(fingerprint.name)
        return omniwm_restore_monitor_key(
            display_id: fingerprint.displayId,
            anchor_x: fingerprint.anchorPoint.x,
            anchor_y: fingerprint.anchorPoint.y,
            frame_width: fingerprint.frameSize.width,
            frame_height: fingerprint.frameSize.height,
            name: nameRef.ref,
            has_name: nameRef.hasValue
        )
    }

    private func makeMonitorKey(
        for restoreKey: MonitorRestoreKey,
        strings: inout KernelStringTable
    ) -> omniwm_restore_monitor_key {
        let nameRef = strings.append(restoreKey.name)
        return omniwm_restore_monitor_key(
            display_id: restoreKey.displayId,
            anchor_x: restoreKey.anchorPoint.x,
            anchor_y: restoreKey.anchorPoint.y,
            frame_width: restoreKey.frameSize.width,
            frame_height: restoreKey.frameSize.height,
            name: nameRef.ref,
            has_name: nameRef.hasValue
        )
    }

    private func makePersistedKey(
        for key: PersistedWindowRestoreKey,
        strings: inout KernelStringTable
    ) -> omniwm_restore_persisted_key {
        let bundleIdRef = strings.append(key.baseKey.bundleId)
        let roleRef = strings.append(key.baseKey.role)
        let subroleRef = strings.append(key.baseKey.subrole)
        let titleRef = strings.append(key.title)
        return omniwm_restore_persisted_key(
            bundle_id: bundleIdRef.ref,
            role: roleRef.ref,
            subrole: subroleRef.ref,
            title: titleRef.ref,
            window_level: key.baseKey.windowLevel ?? 0,
            parent_window_id: key.baseKey.parentWindowId ?? 0,
            has_bundle_id: bundleIdRef.hasValue,
            has_role: roleRef.hasValue,
            has_subrole: subroleRef.hasValue,
            has_title: titleRef.hasValue,
            has_window_level: key.baseKey.windowLevel == nil ? 0 : 1,
            has_parent_window_id: key.baseKey.parentWindowId == nil ? 0 : 1
        )
    }

    private func makeFloatingRescueCandidate(
        token: WindowToken?,
        workspaceId: WorkspaceDescriptor.ID?,
        targetMonitor: Monitor?,
        floatingFrame: CGRect,
        normalizedOrigin: CGPoint?,
        referenceMonitorId: Monitor.ID?,
        currentFrame: CGRect?,
        isScratchpadHidden: Bool,
        isWorkspaceInactiveHidden: Bool
    ) -> omniwm_restore_floating_rescue_candidate {
        let targetVisibleFrame = targetMonitor?.visibleFrame ?? floatingFrame
        return omniwm_restore_floating_rescue_candidate(
            token: encode(optionalToken: token),
            workspace_id: encode(optionalUUID: workspaceId),
            target_monitor_id: rawMonitorId(targetMonitor?.id ?? referenceMonitorId),
            target_monitor_visible_frame: encode(rect: targetVisibleFrame),
            current_frame: encode(rect: currentFrame ?? .zero),
            floating_frame: encode(rect: floatingFrame),
            normalized_origin: encode(point: normalizedOrigin ?? .zero),
            reference_monitor_id: rawMonitorId(referenceMonitorId),
            has_current_frame: currentFrame == nil ? 0 : 1,
            has_normalized_origin: normalizedOrigin == nil ? 0 : 1,
            has_reference_monitor_id: referenceMonitorId == nil ? 0 : 1,
            is_scratchpad_hidden: isScratchpadHidden ? 1 : 0,
            is_workspace_inactive_hidden: isWorkspaceInactiveHidden ? 1 : 0
        )
    }

    private func rawEventKind(_ event: WMEvent) -> UInt32 {
        switch event {
        case .topologyChanged:
            UInt32(OMNIWM_RESTORE_EVENT_KIND_TOPOLOGY_CHANGED)
        case .activeSpaceChanged:
            UInt32(OMNIWM_RESTORE_EVENT_KIND_ACTIVE_SPACE_CHANGED)
        case .systemWake:
            UInt32(OMNIWM_RESTORE_EVENT_KIND_SYSTEM_WAKE)
        case .systemSleep:
            UInt32(OMNIWM_RESTORE_EVENT_KIND_SYSTEM_SLEEP)
        case .windowAdmitted,
             .windowRekeyed,
             .windowRemoved,
             .workspaceAssigned,
             .windowModeChanged,
             .floatingGeometryUpdated,
             .hiddenStateChanged,
             .nativeFullscreenTransition,
             .managedReplacementMetadataChanged,
             .focusLeaseChanged,
             .managedFocusRequested,
             .managedFocusConfirmed,
             .managedFocusCancelled,
             .nonManagedFocusChanged:
            UInt32(OMNIWM_RESTORE_EVENT_KIND_OTHER)
        }
    }

    private func notes(forEventNoteCode code: UInt32) -> [String] {
        switch code {
        case UInt32(OMNIWM_RESTORE_NOTE_TOPOLOGY):
            ["restore_refresh=topology"]
        case UInt32(OMNIWM_RESTORE_NOTE_ACTIVE_SPACE):
            ["restore_refresh=active_space"]
        case UInt32(OMNIWM_RESTORE_NOTE_SYSTEM_WAKE):
            ["restore_refresh=system_wake"]
        case UInt32(OMNIWM_RESTORE_NOTE_SYSTEM_SLEEP):
            ["restore_refresh=system_sleep"]
        default:
            []
        }
    }

    private func rawWindowMode(_ mode: TrackedWindowMode) -> UInt32 {
        switch mode {
        case .tiling:
            UInt32(OMNIWM_RECONCILE_WINDOW_MODE_TILING)
        case .floating:
            UInt32(OMNIWM_RECONCILE_WINDOW_MODE_FLOATING)
        }
    }

    private func trackedWindowMode(from rawValue: UInt32) -> TrackedWindowMode {
        switch rawValue {
        case UInt32(OMNIWM_RECONCILE_WINDOW_MODE_TILING):
            .tiling
        case UInt32(OMNIWM_RECONCILE_WINDOW_MODE_FLOATING):
            .floating
        default:
            preconditionFailure("Unexpected restore target mode \(rawValue)")
        }
    }

    private func namePenalty(lhs: String, rhs: String) -> UInt8 {
        lhs.localizedCaseInsensitiveCompare(rhs) == .orderedSame ? 0 : 1
    }

    private func rawMonitorId(_ monitorId: Monitor.ID?) -> UInt32 {
        monitorId?.displayId ?? 0
    }

    private func encode(rect: CGRect) -> omniwm_rect {
        omniwm_rect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    private func decode(rect: omniwm_rect) -> CGRect {
        CGRect(
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height
        )
    }

    private func encode(point: CGPoint) -> omniwm_point {
        omniwm_point(x: point.x, y: point.y)
    }

    private func encode(uuid: UUID) -> omniwm_uuid {
        let bytes = Array(withUnsafeBytes(of: uuid.uuid) { $0 })
        let high = bytes[0 ..< 8].reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
        let low = bytes[8 ..< 16].reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
        return omniwm_uuid(high: high, low: low)
    }

    private func encode(optionalUUID: UUID?) -> omniwm_uuid {
        optionalUUID.map(encode(uuid:)) ?? zeroUUID()
    }

    private func decode(uuid: omniwm_uuid) -> UUID {
        let b0 = UInt8((uuid.high >> 56) & 0xff)
        let b1 = UInt8((uuid.high >> 48) & 0xff)
        let b2 = UInt8((uuid.high >> 40) & 0xff)
        let b3 = UInt8((uuid.high >> 32) & 0xff)
        let b4 = UInt8((uuid.high >> 24) & 0xff)
        let b5 = UInt8((uuid.high >> 16) & 0xff)
        let b6 = UInt8((uuid.high >> 8) & 0xff)
        let b7 = UInt8(uuid.high & 0xff)
        let b8 = UInt8((uuid.low >> 56) & 0xff)
        let b9 = UInt8((uuid.low >> 48) & 0xff)
        let b10 = UInt8((uuid.low >> 40) & 0xff)
        let b11 = UInt8((uuid.low >> 32) & 0xff)
        let b12 = UInt8((uuid.low >> 24) & 0xff)
        let b13 = UInt8((uuid.low >> 16) & 0xff)
        let b14 = UInt8((uuid.low >> 8) & 0xff)
        let b15 = UInt8(uuid.low & 0xff)
        return UUID(uuid: (b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15))
    }

    private func zeroUUID() -> omniwm_uuid {
        omniwm_uuid(high: 0, low: 0)
    }

    private func zeroToken() -> omniwm_window_token {
        omniwm_window_token(pid: 0, window_id: 0)
    }

    private func encode(token: WindowToken) -> omniwm_window_token {
        omniwm_window_token(pid: token.pid, window_id: Int64(token.windowId))
    }

    private func encode(optionalToken: WindowToken?) -> omniwm_window_token {
        optionalToken.map(encode(token:)) ?? zeroToken()
    }

    private func zeroMonitorKey() -> omniwm_restore_monitor_key {
        omniwm_restore_monitor_key(
            display_id: 0,
            anchor_x: 0,
            anchor_y: 0,
            frame_width: 0,
            frame_height: 0,
            name: omniwm_restore_string_ref(offset: 0, length: 0),
            has_name: 0
        )
    }
}

private struct KernelStringTable {
    private(set) var bytes = ContiguousArray<UInt8>()

    mutating func append(_ string: String?) -> (ref: omniwm_restore_string_ref, hasValue: UInt8) {
        guard let string else {
            return (omniwm_restore_string_ref(offset: 0, length: 0), 0)
        }

        let utf8 = Array(string.utf8)
        let offset = bytes.count
        bytes.append(contentsOf: utf8)
        return (
            omniwm_restore_string_ref(offset: offset, length: utf8.count),
            1
        )
    }
}
