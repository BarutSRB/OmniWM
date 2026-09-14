// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension AXManager {
    func rebindWindowAsync(
        from oldWindow: AXManagedWindowIdentity,
        to newWindow: AXManagedWindowIdentity,
        timeoutSeconds: TimeInterval = 0.5
    ) async -> AXManagedWindowRebindAcknowledgement? {
        let destinationContext: AppAXContext
        if let existing = AppAXContextRegistry.contexts[newWindow.token.pid] {
            destinationContext = existing
        } else {
            guard let app = NSRunningApplication(processIdentifier: newWindow.token.pid),
                  !app.isTerminated,
                  let created = try? await AppAXContextRegistry.getOrCreate(app)
            else {
                return nil
            }
            destinationContext = created
        }

        guard AppAXContextRegistry.contexts[newWindow.token.pid] === destinationContext else {
            return nil
        }
        let oldContext = AppAXContextRegistry.contexts[oldWindow.token.pid]
        let oldCallbackGeneration = oldContext?.callbackGeneration
        let binding: AppAXWindowRebindBinding?
        do {
            binding = try await destinationContext.rebindWindowAsync(
                oldWindowId: oldWindow.token.windowId,
                newWindow: newWindow.axRef,
                timeoutSeconds: timeoutSeconds
            )
        } catch {
            return nil
        }
        guard let binding else { return nil }
        return AXManagedWindowRebindAcknowledgement(
            oldPID: oldWindow.token.pid,
            oldContext: oldContext,
            oldCallbackGeneration: oldCallbackGeneration,
            destinationContext: destinationContext,
            destinationCallbackGeneration: destinationContext.callbackGeneration,
            destinationBinding: binding
        )
    }

    func rollbackWindowRebind(
        _ acknowledgement: AXManagedWindowRebindAcknowledgement,
        newWindow: AXManagedWindowIdentity
    ) {
        acknowledgement.destinationContext.rollbackWindowRebind(
            acknowledgement.destinationBinding,
            newWindow: newWindow.axRef
        )
    }

    func isCurrentWindowRebindAcknowledgement(
        _ acknowledgement: AXManagedWindowRebindAcknowledgement,
        from oldWindow: AXManagedWindowIdentity,
        to newWindow: AXManagedWindowIdentity
    ) -> Bool {
        guard acknowledgement.oldPID == oldWindow.token.pid,
              acknowledgement.destinationContext.pid == newWindow.token.pid,
              AppAXContextRegistry.contexts[newWindow.token.pid] === acknowledgement.destinationContext,
              acknowledgement.destinationContext.callbackGeneration
              == acknowledgement.destinationCallbackGeneration
        else {
            return false
        }
        guard oldWindow.token.pid != newWindow.token.pid else {
            return true
        }
        guard let oldContext = acknowledgement.oldContext else {
            return AppAXContextRegistry.contexts[oldWindow.token.pid] == nil
        }
        return AppAXContextRegistry.contexts[oldWindow.token.pid] === oldContext
            && oldContext.callbackGeneration == acknowledgement.oldCallbackGeneration
    }

    func finalizeWindowRebindContextState(
        from oldWindow: AXManagedWindowIdentity,
        to newWindow: AXManagedWindowIdentity,
        acknowledgement: AXManagedWindowRebindAcknowledgement?
    ) async -> Bool {
        if let acknowledgement {
            guard isCurrentWindowRebindAcknowledgement(
                acknowledgement,
                from: oldWindow,
                to: newWindow
            ) else {
                return false
            }
            guard (try? await acknowledgement.destinationContext.commitWindowRebindAsync(
                oldWindow: oldWindow.axRef,
                newWindow: newWindow.axRef,
                binding: acknowledgement.destinationBinding,
                retireOldWindowState: acknowledgement.oldContext === acknowledgement.destinationContext
            )) == true else {
                return false
            }
            guard isCurrentWindowRebindAcknowledgement(
                acknowledgement,
                from: oldWindow,
                to: newWindow
            ) else {
                return false
            }
            if acknowledgement.oldContext !== acknowledgement.destinationContext {
                if let oldContext = acknowledgement.oldContext,
                   (try? await oldContext.removeWindowStateAsync(
                       expectedWindow: oldWindow.axRef
                   )) == nil
                {
                    return false
                }
            }
            guard isCurrentWindowRebindAcknowledgement(
                acknowledgement,
                from: oldWindow,
                to: newWindow
            ) else {
                return false
            }
        }
        return true
    }

    @discardableResult
    func commitFrameApplicationStateForRebind(
        from oldWindow: AXManagedWindowIdentity,
        to newWindow: AXManagedWindowIdentity,
        acknowledgement: AXManagedWindowRebindAcknowledgement? = nil
    ) -> AXFrameApplicationTarget? {
        let oldWindowId = oldWindow.token.windowId
        let newWindowId = newWindow.token.windowId
        let parkState = parkLedger.rebindState(oldWindowId: oldWindowId, newWindowId: newWindowId)
        let parkFrame = parkState.frame
        let shouldReissuePark = parkState.isPending
            || isWindowParked?(oldWindowId) == true
            || isWindowParked?(newWindowId) == true
        parkLedger.cancelParkFrameJobs(
            [
                (pid: oldWindow.token.pid, windowId: oldWindowId),
                (pid: newWindow.token.pid, windowId: newWindowId)
            ],
            reason: "rekey"
        )
        prepareFrameContextsForRebind(from: oldWindowId, to: newWindowId, acknowledgement: acknowledgement)
        let isIncarnationReplacement = oldWindow.token.pid != newWindow.token.pid
            || oldWindowId == newWindowId
        let deliveries = resetFrameApplicationStateForRebind(
            oldWindowId: oldWindowId,
            newWindowId: newWindowId,
            isIncarnationReplacement: isIncarnationReplacement
        )
        for delivery in deliveries {
            delivery.deliver()
        }
        var retainedParkTarget: AXFrameApplicationTarget?
        if shouldReissuePark {
            parkLedger.markParkPending(for: newWindowId, pid: newWindow.token.pid)
            if let parkFrame {
                retainedParkTarget = AXFrameApplicationTarget(
                    pid: newWindow.token.pid,
                    window: newWindow.axRef,
                    frame: parkFrame
                )
            }
        }
        FrameApplyTrace.recordEvent(
            pid: newWindow.token.pid,
            windowId: oldWindowId,
            outcome: "outcome=rebind→\(newWindowId)"
        )
        return retainedParkTarget
    }

    private func prepareFrameContextsForRebind(
        from oldWindowId: Int,
        to newWindowId: Int,
        acknowledgement: AXManagedWindowRebindAcknowledgement?
    ) {
        if let acknowledgement {
            if acknowledgement.oldContext === acknowledgement.destinationContext {
                acknowledgement.destinationContext.prepareWindowRebind(
                    from: oldWindowId,
                    to: newWindowId
                )
            } else {
                acknowledgement.oldContext?.prepareWindowRemoval(for: oldWindowId)
                acknowledgement.oldContext?.invalidateWindowIdentity()
                acknowledgement.destinationContext.prepareWindowRemoval(for: newWindowId)
                acknowledgement.destinationContext.invalidateWindowIdentity()
            }
        }
    }
}
