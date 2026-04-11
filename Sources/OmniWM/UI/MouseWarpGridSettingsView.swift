import SwiftUI
import CoreGraphics

// MARK: - MouseWarpGridSettingsView

struct MouseWarpGridSettingsView: View {
    @Bindable var settings: SettingsStore
    let connectedMonitors: [Monitor]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            // macOS Display Arrangement notice
            MacOSDisplayArrangementNotice()

            Divider()

            SectionHeader("Virtual Monitor Layout")

            Text(
                "Drag monitors to match your physical arrangement. " +
                "OmniWM uses this layout for mouse warp navigation " +
                "when Warp Axis is set to \"Both\"."
            )
            .font(.caption)
            .foregroundColor(.secondary)

            MouseWarpGridCanvas(
                settings: settings,
                connectedMonitors: connectedMonitors,
                adjacentPairs: adjacentMonitorPairs()
            )

            HStack {
                Spacer()
                Button("Reset to Detected Positions") {
                    settings.mouseWarpGrid = autoDetectedGrid(from: connectedMonitors)
                }
                .buttonStyle(.borderless)
            }

            // Staircase lint warnings
            let warnings = adjacentMonitorPairs()
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(warnings.indices, id: \.self) { i in
                        let pair = warnings[i]
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.system(size: 11, weight: .medium))
                                .padding(.top, 1)
                            Text(
                                "Warning: \(pair.0) and \(pair.1) share an edge. " +
                                "In macOS Display Settings, ensure they are NOT adjacent " +
                                "(use staircase pattern) so OmniWM can control cursor navigation."
                            )
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                        )
                )
            }
        }
    }

    private func autoDetectedGrid(from monitors: [Monitor]) -> [MouseWarpGridEntry] {
        monitors.map { monitor in
            MouseWarpGridEntry(
                name: monitor.name,
                x: monitor.frame.minX,
                y: monitor.frame.minY
            )
        }
    }

    /// Returns pairs of monitor names whose virtual edges are directly adjacent.
    /// Tolerance of 5 virtual points is used for edge comparison.
    func adjacentMonitorPairs() -> [(String, String)] {
        let tolerance: CGFloat = 5
        let entries = settings.mouseWarpGrid.isEmpty
            ? autoDetectedGrid(from: connectedMonitors)
            : settings.mouseWarpGrid

        func size(for entry: MouseWarpGridEntry) -> CGSize {
            if let monitor = connectedMonitors.first(where: { $0.name == entry.name }) {
                return CGSize(width: monitor.frame.width, height: monitor.frame.height)
            }
            return CGSize(width: 1920, height: 1080)
        }

        var pairs: [(String, String)] = []
        var seen: Set<String> = []

        for i in entries.indices {
            for j in entries.indices where j != i {
                let a = entries[i]
                let b = entries[j]
                let key = [a.name, b.name].sorted().joined(separator: "|")
                guard !seen.contains(key) else { continue }

                let sizeA = size(for: a)
                let sizeB = size(for: b)

                // Check side-by-side: A's right edge == B's left edge, with Y overlap
                let sideBySide = abs((a.x + sizeA.width) - b.x) < tolerance
                let yOverlap = a.y < (b.y + sizeB.height) && (a.y + sizeA.height) > b.y
                if sideBySide && yOverlap {
                    pairs.append((a.name, b.name))
                    seen.insert(key)
                    continue
                }

                // Check stacked: A's top edge == B's bottom edge, with X overlap
                let stacked = abs((a.y + sizeA.height) - b.y) < tolerance
                let xOverlap = a.x < (b.x + sizeB.width) && (a.x + sizeA.width) > b.x
                if stacked && xOverlap {
                    pairs.append((a.name, b.name))
                    seen.insert(key)
                }
            }
        }

        return pairs
    }
}

// MARK: - MacOSDisplayArrangementNotice

private struct MacOSDisplayArrangementNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 14, weight: .medium))
                    .padding(.top, 1)

                Text("macOS Display Arrangement")
                    .font(.system(size: 13, weight: .semibold))
            }

            Text(
                "OmniWM requires monitors to be arranged in a staircase pattern in macOS " +
                "System Settings → Displays → Arrange. This prevents macOS from naturally " +
                "moving the cursor between monitors — OmniWM's mouse warp handles navigation " +
                "instead, using the virtual layout below."
            )
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text(
                "OmniWM hides windows by moving them off-screen to the sides. If monitors " +
                "share edges in macOS settings, windows could appear on adjacent displays. " +
                "The staircase pattern prevents this — OmniWM's mouse warp handles navigation instead."
            )
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            // Visual staircase example
            VStack(alignment: .leading, spacing: 2) {
                Text("Your macOS Displays → Arrange should look like this:")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                HStack(alignment: .top, spacing: 0) {
                    // Staircase diagram
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .bottom, spacing: 1) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.blue.opacity(0.15))
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.blue.opacity(0.4), lineWidth: 0.5))
                                .frame(width: 40, height: 22)
                                .overlay(Text("Main").font(.system(size: 5)).foregroundColor(.blue))
                        }
                        HStack(alignment: .bottom, spacing: 1) {
                            Spacer().frame(width: 42)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.green.opacity(0.15))
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.green.opacity(0.4), lineWidth: 0.5))
                                .frame(width: 30, height: 18)
                                .overlay(Text("2nd").font(.system(size: 5)).foregroundColor(.green))
                        }
                        HStack(alignment: .bottom, spacing: 1) {
                            Spacer().frame(width: 74)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.purple.opacity(0.15))
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.purple.opacity(0.4), lineWidth: 0.5))
                                .frame(width: 30, height: 18)
                                .overlay(Text("3rd").font(.system(size: 5)).foregroundColor(.purple))
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("← Staircase pattern")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.orange)
                        Text("No edges touching")
                            .font(.system(size: 7))
                            .foregroundColor(.secondary)
                    }
                    .padding(.leading, 8)
                    .padding(.top, 8)
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.05))
                )
            }

            Button("Open Display Settings") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.displays")!
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.orange.opacity(0.25), lineWidth: 1)
                )
        )
    }
}

// MARK: - SnapGuide

/// Represents a single alignment guide line to be drawn over the canvas during drag.
private struct SnapGuide {
    enum Axis { case horizontal, vertical }
    let axis: Axis
    /// Position along the perpendicular axis in canvas coordinates (x for vertical, y for horizontal).
    let position: CGFloat
}

// MARK: - MouseWarpGridCanvas

private struct MouseWarpGridCanvas: View {
    @Bindable var settings: SettingsStore
    let connectedMonitors: [Monitor]
    let adjacentPairs: [(String, String)]

    // Canvas display size
    private let canvasWidth: CGFloat = 460
    private let canvasHeight: CGFloat = 200

    // Snap distance in virtual coordinate space
    private let snapThreshold: CGFloat = 25

    // Active snap guides (shown while dragging)
    @State private var activeGuides: [SnapGuide] = []
    // Original grid positions at drag start — prevents compounding delta
    @State private var dragStartGrid: [MouseWarpGridEntry]?

    var body: some View {
        let entries = effectiveEntries()
        let scale = computeScale(for: entries)
        let offset = computeOffset(for: entries, scale: scale)

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                )

            // Snap guide lines drawn beneath tiles
            ForEach(activeGuides.indices, id: \.self) { i in
                SnapGuideLine(guide: activeGuides[i], canvasWidth: canvasWidth, canvasHeight: canvasHeight)
            }

            ForEach(entries.indices, id: \.self) { index in
                let entry = entries[index]
                let frame = displayFrame(for: entry, scale: scale, offset: offset)
                let hasWarning = adjacentPairs.contains(where: { $0.0 == entry.name || $0.1 == entry.name })

                GridMonitorTile(
                    entry: entry,
                    frame: frame,
                    isMain: isMainMonitor(named: entry.name),
                    hasWarning: hasWarning,
                    onDrag: { dragDelta in
                        handleDrag(
                            index: index,
                            delta: dragDelta,
                            allEntries: entries,
                            scale: scale,
                            offset: offset
                        )
                    },
                    onDragEnd: {
                        activeGuides = []
                        dragStartGrid = nil
                    }
                )
            }
        }
        .frame(width: canvasWidth, height: canvasHeight)
        .onAppear {
            if settings.mouseWarpGrid.isEmpty {
                settings.mouseWarpGrid = autoDetectedGrid(from: connectedMonitors)
            }
        }
    }

    // MARK: - Effective entries (merged with connected monitors for dimensions)

    private func effectiveEntries() -> [MouseWarpGridEntry] {
        if settings.mouseWarpGrid.isEmpty {
            return autoDetectedGrid(from: connectedMonitors)
        }
        return settings.mouseWarpGrid
    }

    private func autoDetectedGrid(from monitors: [Monitor]) -> [MouseWarpGridEntry] {
        monitors.map { monitor in
            MouseWarpGridEntry(
                name: monitor.name,
                x: monitor.frame.minX,
                y: monitor.frame.minY
            )
        }
    }

    // MARK: - Monitor dimensions

    private func monitorSize(for name: String) -> CGSize {
        if let monitor = connectedMonitors.first(where: { $0.name == name }) {
            return CGSize(width: monitor.frame.width, height: monitor.frame.height)
        }
        // Fallback if no connected monitor matches
        return CGSize(width: 1920, height: 1080)
    }

    private func isMainMonitor(named name: String) -> Bool {
        connectedMonitors.first(where: { $0.name == name })?.isMain ?? false
    }

    // MARK: - Scale / offset computation

    /// Bounding box of all virtual monitor rects in virtual coordinate space
    private func virtualBounds(for entries: [MouseWarpGridEntry]) -> CGRect {
        guard !entries.isEmpty else {
            return CGRect(x: 0, y: 0, width: 1920, height: 1080)
        }

        var minX = CGFloat.infinity
        var minY = CGFloat.infinity
        var maxX = -CGFloat.infinity
        var maxY = -CGFloat.infinity

        for entry in entries {
            let size = monitorSize(for: entry.name)
            minX = min(minX, entry.x)
            minY = min(minY, entry.y)
            maxX = max(maxX, entry.x + size.width)
            maxY = max(maxY, entry.y + size.height)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private let canvasPadding: CGFloat = 20

    private func computeScale(for entries: [MouseWarpGridEntry]) -> CGFloat {
        let bounds = virtualBounds(for: entries)
        guard bounds.width > 0, bounds.height > 0 else { return 1 }

        let availableWidth = canvasWidth - canvasPadding * 2
        let availableHeight = canvasHeight - canvasPadding * 2

        let scaleX = availableWidth / bounds.width
        let scaleY = availableHeight / bounds.height
        return min(scaleX, scaleY)
    }

    /// Returns the canvas offset so that the virtual bounding box is centered in the canvas.
    /// Uses flipped Y: virtual maxY maps to canvas top.
    private func computeOffset(for entries: [MouseWarpGridEntry], scale: CGFloat) -> CGPoint {
        let bounds = virtualBounds(for: entries)
        let scaledWidth = bounds.width * scale
        let scaledHeight = bounds.height * scale
        let centerX = (canvasWidth - scaledWidth) / 2
        let centerY = (canvasHeight - scaledHeight) / 2
        return CGPoint(
            x: centerX - bounds.minX * scale,
            y: centerY + bounds.maxY * scale
        )
    }

    /// Returns the rect in canvas coordinates for a given grid entry.
    /// Flips the Y axis: AppKit uses y-up (higher Y = above) but SwiftUI uses y-down.
    private func displayFrame(
        for entry: MouseWarpGridEntry,
        scale: CGFloat,
        offset: CGPoint
    ) -> CGRect {
        let size = monitorSize(for: entry.name)
        // Flip Y: negate virtual Y so higher values appear at top of canvas
        return CGRect(
            x: entry.x * scale + offset.x,
            y: -entry.y * scale - size.height * scale + offset.y,
            width: size.width * scale,
            height: size.height * scale
        )
    }

    // MARK: - Drag handling

    private func handleDrag(
        index: Int,
        delta: CGSize,
        allEntries: [MouseWarpGridEntry],
        scale: CGFloat,
        offset: CGPoint
    ) {
        guard index < settings.mouseWarpGrid.count else { return }

        // Store original positions on first drag event
        if dragStartGrid == nil {
            dragStartGrid = settings.mouseWarpGrid
        }
        guard let startGrid = dragStartGrid, index < startGrid.count else { return }

        let virtualDeltaX = delta.width / scale
        let virtualDeltaY = -delta.height / scale  // Negate: SwiftUI y-down → AppKit y-up

        // Compute from ORIGINAL position, not current (prevents compounding)
        let originalEntry = startGrid[index]
        var entry = settings.mouseWarpGrid[index]
        var newX = originalEntry.x + virtualDeltaX
        var newY = originalEntry.y + virtualDeltaY

        let size = monitorSize(for: entry.name)
        let draggedCenterX = newX + size.width / 2
        let draggedCenterY = newY + size.height / 2

        var newGuides: [SnapGuide] = []

        // Find best X and Y snap independently across ALL other monitors
        // This allows snapping to two monitors at once (e.g., side of one + bottom of another)
        var bestXSnap: (dist: CGFloat, newX: CGFloat, guidePos: CGFloat)? = nil
        var bestYSnap: (dist: CGFloat, newY: CGFloat, guidePos: CGFloat)? = nil

        for otherIndex in settings.mouseWarpGrid.indices where otherIndex != index {
            let other = settings.mouseWarpGrid[otherIndex]
            let otherSize = monitorSize(for: other.name)
            let otherCenterX = other.x + otherSize.width / 2
            let otherCenterY = other.y + otherSize.height / 2

            // All X snap candidates: (distance, snappedX, guideX)
            let xCandidates: [(CGFloat, CGFloat, CGFloat)] = [
                (abs(newX - (other.x + otherSize.width)), other.x + otherSize.width, other.x + otherSize.width),
                (abs((newX + size.width) - other.x), other.x - size.width, other.x),
                (abs(newX - other.x), other.x, other.x),
                (abs((newX + size.width) - (other.x + otherSize.width)), other.x + otherSize.width - size.width, other.x + otherSize.width),
                (abs(draggedCenterX - otherCenterX), otherCenterX - size.width / 2, otherCenterX),
            ]

            for (dist, snapped, guide) in xCandidates where dist < snapThreshold {
                if bestXSnap == nil || dist < bestXSnap!.dist {
                    bestXSnap = (dist, snapped, guide * scale + offset.x)
                }
            }

            // All Y snap candidates: (distance, snappedY, guideY)
            let yCandidates: [(CGFloat, CGFloat, CGFloat)] = [
                (abs(newY - (other.y + otherSize.height)), other.y + otherSize.height, other.y + otherSize.height),
                (abs((newY + size.height) - other.y), other.y - size.height, other.y),
                (abs(newY - other.y), other.y, other.y),
                (abs((newY + size.height) - (other.y + otherSize.height)), other.y + otherSize.height - size.height, other.y + otherSize.height),
                (abs(draggedCenterY - otherCenterY), otherCenterY - size.height / 2, otherCenterY),
            ]

            for (dist, snapped, guide) in yCandidates where dist < snapThreshold {
                if bestYSnap == nil || dist < bestYSnap!.dist {
                    bestYSnap = (dist, snapped, guide * scale + offset.y)
                }
            }
        }

        // Apply best snaps independently
        if let snap = bestXSnap {
            newX = snap.newX
            newGuides.append(SnapGuide(axis: .vertical, position: snap.guidePos))
        }
        if let snap = bestYSnap {
            newY = snap.newY
            newGuides.append(SnapGuide(axis: .horizontal, position: snap.guidePos))
        }

        entry.x = newX
        entry.y = newY
        settings.mouseWarpGrid[index] = entry
        activeGuides = newGuides
    }
}

// MARK: - SnapGuideLine

/// Renders a single dashed guide line across the canvas at a given canvas-space position.
private struct SnapGuideLine: View {
    let guide: SnapGuide
    let canvasWidth: CGFloat
    let canvasHeight: CGFloat

    var body: some View {
        if guide.axis == .vertical {
            // Vertical line at x = guide.position
            Rectangle()
                .fill(Color.clear)
                .frame(width: 1, height: canvasHeight)
                .overlay(
                    DashedLine(isVertical: true)
                )
                .position(x: guide.position, y: canvasHeight / 2)
        } else {
            // Horizontal line at y = guide.position
            Rectangle()
                .fill(Color.clear)
                .frame(width: canvasWidth, height: 1)
                .overlay(
                    DashedLine(isVertical: false)
                )
                .position(x: canvasWidth / 2, y: guide.position)
        }
    }
}

// MARK: - DashedLine

private struct DashedLine: View {
    let isVertical: Bool

    var body: some View {
        GeometryReader { geo in
            Path { path in
                if isVertical {
                    path.move(to: CGPoint(x: 0, y: 0))
                    path.addLine(to: CGPoint(x: 0, y: geo.size.height))
                } else {
                    path.move(to: CGPoint(x: 0, y: 0))
                    path.addLine(to: CGPoint(x: geo.size.width, y: 0))
                }
            }
            .stroke(
                Color.purple.opacity(0.75),
                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
            )
        }
    }
}

// MARK: - GridMonitorTile

private struct GridMonitorTile: View {
    let entry: MouseWarpGridEntry
    let frame: CGRect
    let isMain: Bool
    let hasWarning: Bool
    let onDrag: (CGSize) -> Void
    let onDragEnd: () -> Void

    var body: some View {
        // Tile always renders at the frame position computed from settings store
        let displayedX = frame.minX
        let displayedY = frame.minY

        ZStack(alignment: .topTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(isMain ? 0.18 : 0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                hasWarning ? Color.orange.opacity(0.7) : Color.accentColor.opacity(isMain ? 0.7 : 0.35),
                                lineWidth: hasWarning ? 1.5 : (isMain ? 1.5 : 1)
                            )
                    )

                VStack(spacing: 3) {
                    Image(systemName: "display")
                        .font(.system(size: min(frame.width * 0.18, 16), weight: .medium))
                        .foregroundColor(isMain ? .accentColor : .secondary)

                    Text(entry.name)
                        .font(.system(size: min(frame.width * 0.075, 9), weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 3)

                    if isMain {
                        Text("Main")
                            .font(.system(size: min(frame.width * 0.065, 8), weight: .medium, design: .rounded))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                }
                .padding(4)
            }
            .frame(width: frame.width, height: frame.height)

            // Warning badge in top-right corner
            if hasWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: min(frame.width * 0.15, 12), weight: .bold))
                    .foregroundColor(.orange)
                    .padding(3)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .position(x: displayedX + frame.width / 2, y: displayedY + frame.height / 2)
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    onDrag(value.translation)
                }
                .onEnded { value in
                    onDrag(value.translation)
                    onDragEnd()
                }
        )
    }
}
