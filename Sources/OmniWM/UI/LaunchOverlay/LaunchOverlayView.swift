// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import QuartzCore

@MainActor
final class LaunchOverlayPanel: NSPanel {
    private let overlay: LaunchOverlayView

    init(screen: NSScreen) {
        overlay = LaunchOverlayView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            scale: screen.backingScaleFactor
        )
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = overlay
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    func startAnimation(at startTime: CFTimeInterval) {
        overlay.startAnimation(at: startTime)
    }

    func teardown() {
        overlay.teardown()
    }
}

@MainActor
final class LaunchOverlayView: NSView {
    static let totalDuration: CFTimeInterval = 2.6

    private let scale: CGFloat
    private let tiles = CALayer()
    private var tileLayers: [CALayer] = []
    private let bloom = CAGradientLayer()
    private let wordmark = CAShapeLayer()
    private let writeMask = CAShapeLayer()

    init(frame: CGRect, scale: CGFloat) {
        self.scale = scale
        super.init(frame: frame)
        wantsLayer = true
        buildLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func buildLayers() {
        guard let host = layer else { return }
        host.contentsScale = scale
        configureTiles()
        configureBloom()
        configureWordmark(wordRect: wordmarkRect())
        for sublayer in [tiles, bloom, wordmark] as [CALayer] {
            sublayer.contentsScale = scale
            host.addSublayer(sublayer)
        }
    }

    private func configureTiles() {
        tiles.frame = bounds
        for _ in 0 ..< 5 {
            let tile = CALayer()
            tile.backgroundColor = NSColor(white: 0, alpha: 0.42).cgColor
            tile.borderColor = NSColor(white: 1, alpha: 0.22).cgColor
            tile.borderWidth = 1
            tile.cornerRadius = 10
            tile.opacity = 0
            tile.contentsScale = scale
            tiles.addSublayer(tile)
            tileLayers.append(tile)
        }
    }

    private func configureBloom() {
        let side = min(bounds.width, bounds.height) * 1.4
        bloom.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        bloom.type = .radial
        bloom.colors = [NSColor(white: 1, alpha: 0.35).cgColor, NSColor(white: 1, alpha: 0).cgColor]
        bloom.locations = [0, 1]
        bloom.startPoint = CGPoint(x: 0.5, y: 0.5)
        bloom.endPoint = CGPoint(x: 1, y: 1)
        bloom.opacity = 0
    }

    private func configureWordmark(wordRect: CGRect) {
        wordmark.frame = bounds
        wordmark.path = OmniWMBrandMark.omniWordmarkPath(in: wordRect)
        wordmark.fillColor = NSColor.white.cgColor
        wordmark.strokeColor = NSColor.clear.cgColor

        let line = CGMutablePath()
        line.move(to: CGPoint(x: wordRect.minX, y: wordRect.midY))
        line.addLine(to: CGPoint(x: wordRect.maxX, y: wordRect.midY))
        writeMask.frame = bounds
        writeMask.path = line
        writeMask.fillColor = NSColor.clear.cgColor
        writeMask.strokeColor = NSColor.white.cgColor
        writeMask.lineWidth = wordRect.height * 1.5
        writeMask.lineCap = .round
        writeMask.strokeEnd = 0
        writeMask.contentsScale = scale
        wordmark.mask = writeMask
    }

    private func wordmarkRect() -> CGRect {
        let aspect = OmniWMBrandMark.omniWordmarkAspect
        let width = min(bounds.width * 0.45, 600)
        let height = width / aspect
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    func startAnimation(at t0: CFTimeInterval) {
        let easeOut = CAMediaTimingFunction(name: .easeOut)
        let hand = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.5, 1)

        let choreography = DwindleBuildChoreography(bounds: bounds, gap: 10)
        for (tile, track) in zip(tileLayers, choreography.tracks) {
            addTileTrack(track, to: tile, at: t0)
        }

        writeMask.strokeEnd = 1
        run("strokeEnd", [0, 1], over: (t0 + 0.18) ... (t0 + 1.6), timing: hand, on: writeMask)

        run("opacity", [0, 0.28, 0], over: (t0 + 1.45) ... (t0 + 1.95), on: bloom)
        run("transform.scale", [0.3, 1.2], over: (t0 + 1.45) ... (t0 + 1.95), timing: easeOut, on: bloom)

        if let host = layer {
            run("opacity", [1, 0], over: (t0 + 2.05) ... (t0 + 2.55), timing: easeOut, on: host)
            run(
                "transform.translation.x",
                [0, -bounds.width * 1.3],
                over: (t0 + 2.05) ... (t0 + 2.55),
                timing: easeOut,
                on: host
            )
        }
    }

    func teardown() {
        writeMask.removeAllAnimations()
        layer?.removeAllAnimations()
        for sublayer in layer?.sublayers ?? [] {
            sublayer.removeAllAnimations()
        }
        for tile in tileLayers {
            tile.removeAllAnimations()
        }
    }

    private func addTileTrack(_ track: DwindleBuildChoreography.TileTrack, to tile: CALayer, at t0: CFTimeInterval) {
        if let lastPosition = track.positions.last { tile.position = lastPosition }
        if let lastSize = track.sizes.last { tile.bounds = CGRect(origin: .zero, size: lastSize) }
        tile.opacity = Float(track.opacities.last ?? 1)

        let keyTimes = track.keyTimes.map { NSNumber(value: $0) }
        let position = CAKeyframeAnimation(keyPath: "position")
        position.values = track.positions.map { NSValue(point: $0) }
        let size = CAKeyframeAnimation(keyPath: "bounds")
        size.values = track.sizes.map { NSValue(rect: CGRect(origin: .zero, size: $0)) }
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = track.opacities.map { NSNumber(value: Double($0)) }

        for animation in [position, size, opacity] {
            animation.keyTimes = keyTimes
            animation.timingFunctions = track.timings
            animation.beginTime = t0
            animation.duration = DwindleBuildChoreography.buildDuration
            animation.fillMode = .both
            animation.isRemovedOnCompletion = false
        }
        tile.add(position, forKey: "position")
        tile.add(size, forKey: "bounds")
        tile.add(opacity, forKey: "opacity")
    }

    private func run(
        _ keyPath: String,
        _ values: [CGFloat],
        over window: ClosedRange<CFTimeInterval>,
        timing: CAMediaTimingFunction? = nil,
        on layer: CALayer
    ) {
        let animation: CAPropertyAnimation
        if values.count <= 2 {
            let basic = CABasicAnimation(keyPath: keyPath)
            basic.fromValue = values.first
            basic.toValue = values.last
            basic.timingFunction = timing
            animation = basic
        } else {
            let keyframe = CAKeyframeAnimation(keyPath: keyPath)
            keyframe.values = values
            animation = keyframe
        }
        animation.beginTime = window.lowerBound
        animation.duration = window.upperBound - window.lowerBound
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: keyPath)
    }
}
