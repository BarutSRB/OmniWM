// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation
import os

extension CGPoint {
    func flipY(maxY: CGFloat) -> CGPoint {
        CGPoint(x: x, y: maxY - y)
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    func approximatelyEqual(to other: CGRect, tolerance: CGFloat = 10) -> Bool {
        abs(origin.x - other.origin.x) < tolerance &&
        abs(origin.y - other.origin.y) < tolerance &&
        abs(width - other.width) < tolerance &&
        abs(height - other.height) < tolerance
    }
}

enum ScreenCoordinateSpace {
    struct ScreenTransform {
        let displayId: CGDirectDisplayID
        let appKitFrame: CGRect
        let quartzFrame: CGRect
        let scaleX: CGFloat
        let scaleY: CGFloat
        let backingScale: CGFloat

        func toAppKit(point: CGPoint) -> CGPoint {
            let dx = point.x - quartzFrame.minX
            let dy = point.y - quartzFrame.minY
            let x = appKitFrame.minX + (dx / scaleX)
            let y = appKitFrame.maxY - (dy / scaleY)
            return CGPoint(x: x, y: y)
        }

        func toWindowServer(point: CGPoint) -> CGPoint {
            let dx = point.x - appKitFrame.minX
            let dy = appKitFrame.maxY - point.y
            let x = quartzFrame.minX + (dx * scaleX)
            let y = quartzFrame.minY + (dy * scaleY)
            return CGPoint(x: x, y: y)
        }

        func toAppKit(rect: CGRect) -> CGRect {
            let dx = rect.origin.x - quartzFrame.minX
            let dy = rect.origin.y - quartzFrame.minY
            let x = appKitFrame.minX + (dx / scaleX)
            let height = rect.size.height / scaleY
            let width = rect.size.width / scaleX
            let y = appKitFrame.maxY - (dy / scaleY) - height
            return CGRect(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
        }

        func toWindowServer(rect: CGRect) -> CGRect {
            let dx = rect.origin.x - appKitFrame.minX
            let dy = appKitFrame.maxY - rect.origin.y - rect.size.height
            let x = quartzFrame.minX + (dx * scaleX)
            let y = quartzFrame.minY + (dy * scaleY)
            let width = rect.size.width * scaleX
            let height = rect.size.height * scaleY
            return CGRect(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
        }
    }

    struct DisplayGeometrySnapshot {
        let transforms: [ScreenTransform]
        let globalFrame: CGRect
        let backingScaleByDisplayId: [CGDirectDisplayID: CGFloat]
        let generation: UInt64

        static let empty = DisplayGeometrySnapshot(
            transforms: [],
            globalFrame: .zero,
            backingScaleByDisplayId: [:],
            generation: 0
        )
    }

    nonisolated(unsafe) private static var currentSnapshot: DisplayGeometrySnapshot = .empty
    nonisolated(unsafe) private static var snapshotLock = os_unfair_lock_s()
    nonisolated(unsafe) private static var nextGeneration: UInt64 = 1

    @MainActor
    static func invalidateDisplaySnapshot() {
        let snapshot = buildSnapshotOnMain()
        publish(snapshot)
    }

    @MainActor
    private static func buildSnapshotOnMain() -> DisplayGeometrySnapshot {
        let screens = NSScreen.screens
        var transforms: [ScreenTransform] = []
        transforms.reserveCapacity(screens.count)
        var backingScaleByDisplayId: [CGDirectDisplayID: CGFloat] = [:]
        backingScaleByDisplayId.reserveCapacity(screens.count)

        var globalFrame = CGRect.null
        for screen in screens {
            globalFrame = globalFrame.union(screen.frame)
            guard let displayId = screen.displayId else { continue }
            let quartzFrame = CGDisplayBounds(displayId)
            let appKitFrame = screen.frame
            let scaleX = quartzFrame.width / max(1.0, appKitFrame.width)
            let scaleY = quartzFrame.height / max(1.0, appKitFrame.height)
            let backingScale = screen.backingScaleFactor
            transforms.append(
                ScreenTransform(
                    displayId: displayId,
                    appKitFrame: appKitFrame,
                    quartzFrame: quartzFrame,
                    scaleX: scaleX,
                    scaleY: scaleY,
                    backingScale: backingScale
                )
            )
            backingScaleByDisplayId[displayId] = backingScale
        }

        let generation = nextGeneration
        nextGeneration &+= 1
        return DisplayGeometrySnapshot(
            transforms: transforms,
            globalFrame: globalFrame.isNull ? .zero : globalFrame,
            backingScaleByDisplayId: backingScaleByDisplayId,
            generation: generation
        )
    }

    private static func publish(_ snapshot: DisplayGeometrySnapshot) {
        os_unfair_lock_lock(&snapshotLock)
        currentSnapshot = snapshot
        os_unfair_lock_unlock(&snapshotLock)
    }

    static func snapshot() -> DisplayGeometrySnapshot {
        os_unfair_lock_lock(&snapshotLock)
        let snapshot = currentSnapshot
        os_unfair_lock_unlock(&snapshotLock)
        if snapshot.generation == 0, Thread.isMainThread {
            return MainActor.assumeIsolated {
                let rebuilt = buildSnapshotOnMain()
                publish(rebuilt)
                return rebuilt
            }
        }
        return snapshot
    }

    static var globalFrame: CGRect {
        snapshot().globalFrame
    }

    static func backingScale(forAppKitRect rect: CGRect, fallback: CGFloat = 2.0) -> CGFloat {
        let snap = snapshot()
        let center = rect.center
        for transform in snap.transforms where transform.appKitFrame.contains(center) {
            return transform.backingScale
        }
        return snap.transforms.first?.backingScale ?? fallback
    }

    private static func transformForQuartz(point: CGPoint, in snap: DisplayGeometrySnapshot) -> ScreenTransform? {
        snap.transforms.first { $0.quartzFrame.contains(point) }
    }

    private static func transformForAppKit(point: CGPoint, in snap: DisplayGeometrySnapshot) -> ScreenTransform? {
        snap.transforms.first { $0.appKitFrame.contains(point) }
    }

    private static func transformClosestToQuartz(point: CGPoint, in snap: DisplayGeometrySnapshot) -> ScreenTransform? {
        if let transform = transformForQuartz(point: point, in: snap) {
            return transform
        }
        return snap.transforms.min { lhs, rhs in
            lhs.quartzFrame.distanceSquared(to: point) < rhs.quartzFrame.distanceSquared(to: point)
        }
    }

    private static func transformClosestToAppKit(point: CGPoint, in snap: DisplayGeometrySnapshot) -> ScreenTransform? {
        if let transform = transformForAppKit(point: point, in: snap) {
            return transform
        }
        return snap.transforms.min { lhs, rhs in
            lhs.appKitFrame.distanceSquared(to: point) < rhs.appKitFrame.distanceSquared(to: point)
        }
    }

    static func toAppKit(point: CGPoint) -> CGPoint {
        let snap = snapshot()
        if let transform = transformClosestToQuartz(point: point, in: snap) {
            return transform.toAppKit(point: point)
        }
        return CGPoint(x: point.x, y: snap.globalFrame.maxY - point.y)
    }

    static func toAppKit(rect: CGRect) -> CGRect {
        let snap = snapshot()
        if let transform = transformClosestToQuartz(point: rect.center, in: snap) {
            return transform.toAppKit(rect: rect)
        }
        let flippedY = snap.globalFrame.maxY - (rect.origin.y + rect.size.height)
        return CGRect(origin: CGPoint(x: rect.origin.x, y: flippedY), size: rect.size)
    }

    static func toWindowServer(point: CGPoint) -> CGPoint {
        let snap = snapshot()
        if let transform = transformClosestToAppKit(point: point, in: snap) {
            return transform.toWindowServer(point: point)
        }
        return CGPoint(x: point.x, y: snap.globalFrame.maxY - point.y)
    }

    static func toWindowServer(rect: CGRect) -> CGRect {
        let snap = snapshot()
        if let transform = transformClosestToAppKit(point: rect.center, in: snap) {
            return transform.toWindowServer(rect: rect)
        }
        let flippedY = snap.globalFrame.maxY - (rect.origin.y + rect.size.height)
        return CGRect(origin: CGPoint(x: rect.origin.x, y: flippedY), size: rect.size)
    }
}

extension NSScreen {
    static func screen(containing point: CGPoint) -> NSScreen? {
        screens.first(where: { $0.frame.contains(point) })
    }

    static func screen(containing rect: CGRect) -> NSScreen? {
        screens.first(where: { $0.frame.intersects(rect) })
            ?? screen(containing: rect.center)
    }
}
