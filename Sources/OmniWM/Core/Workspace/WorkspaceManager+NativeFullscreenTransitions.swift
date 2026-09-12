// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    func nativeFullscreenOriginalToken(forCurrentToken token: WindowToken) -> WindowToken? {
        return nativeFullscreenOriginalTokenByCurrentToken[token]
    }

    @discardableResult
    func expireNativeFullscreenTransition(originalToken: WindowToken, generation: Int) -> Bool {
        guard var record = nativeFullscreenRecordsByOriginalToken[originalToken],
              record.transitionGeneration == generation
        else { return false }
        switch record.transition {
        case .suspended:
            return false
        case .enterRequested:
            _ = removeNativeFullscreenRecord(originalToken: originalToken)
            drainPendingRuntimeMonitorOverrideClears()
            return true
        case .exitRequested:
            record.transition = .suspended
            upsertNativeFullscreenRecord(record)
            return true
        }
    }

    @discardableResult
    func upsertNativeFullscreenRecord(_ record: NativeFullscreenRecord) -> NativeFullscreenRecord {
        var record = record
        let previousRecord = nativeFullscreenRecordsByOriginalToken[record.originalToken]
        var transitionChanged = false
        if let previous = previousRecord {
            if previous.transition != record.transition {
                transitionChanged = true
                nativeFullscreenTransitionGenerationCounter += 1
                record.transitionGeneration = nativeFullscreenTransitionGenerationCounter
            } else {
                record.transitionGeneration = previous.transitionGeneration
            }
            nativeFullscreenOriginalTokenByCurrentToken.removeValue(forKey: previous.currentToken)
            if previous != record {
                noteInvalidation(workspaceId: previous.workspaceId, domains: [.workspace, .layout, .focus, .fullscreen])
                if previous.workspaceId != record.workspaceId {
                    noteInvalidation(
                        workspaceId: record.workspaceId,
                        domains: [.workspace, .layout, .focus, .fullscreen]
                    )
                }
            }
        } else {
            transitionChanged = true
            nativeFullscreenTransitionGenerationCounter += 1
            record.transitionGeneration = nativeFullscreenTransitionGenerationCounter
            noteInvalidation(workspaceId: record.workspaceId, domains: [.workspace, .layout, .focus, .fullscreen])
        }
        nativeFullscreenRecordsByOriginalToken[record.originalToken] = record
        nativeFullscreenOriginalTokenByCurrentToken[record.currentToken] = record.originalToken
        if previousRecord != record {
            NativeFullscreenPlaceholderTrace.record(
                NativeFullscreenPlaceholderTrace.makeRecord(
                    .recordUpsert,
                    originalToken: record.originalToken,
                    currentToken: record.currentToken,
                    workspaceId: record.workspaceId,
                    transition: .init(record.transition),
                    generation: record.transitionGeneration
                )
            )
        }
        if transitionChanged {
            updateNativeFullscreenTransitionTimeout(for: record)
        }
        return record
    }

    @discardableResult
    func removeNativeFullscreenRecord(
        originalToken: WindowToken,
        clearsNativeFocusOwner: Bool = true
    ) -> NativeFullscreenRecord? {
        guard let record = nativeFullscreenRecordsByOriginalToken.removeValue(forKey: originalToken) else {
            return nil
        }
        let clearsFocusTarget = clearsNativeFocusOwner && externalFocusToken == record.currentToken
        let clearsNativeFocus = clearsFocusTarget
        nativeFullscreenOriginalTokenByCurrentToken.removeValue(forKey: record.currentToken)
        cancelNativeFullscreenTransitionTimeout(originalToken: originalToken)
        if clearsNativeFocus {
            _ = clearNativeFocusOwner()
        }
        if clearsFocusTarget {
            clearExternalFocusIdentity(matching: record.currentToken)
        }
        noteInvalidation(workspaceId: record.workspaceId, domains: [.workspace, .layout, .focus, .fullscreen])
        NativeFullscreenPlaceholderTrace.record(
            NativeFullscreenPlaceholderTrace.makeRecord(
                .recordRemoved,
                originalToken: record.originalToken,
                currentToken: record.currentToken,
                workspaceId: record.workspaceId,
                transition: .init(record.transition),
                generation: record.transitionGeneration
            )
        )
        return record
    }

    @discardableResult
    func removeNativeFullscreenRecord(containing token: WindowToken) -> NativeFullscreenRecord? {
        guard let originalToken = nativeFullscreenOriginalToken(forCurrentToken: token) else {
            return nil
        }
        return removeNativeFullscreenRecord(originalToken: originalToken)
    }
}
