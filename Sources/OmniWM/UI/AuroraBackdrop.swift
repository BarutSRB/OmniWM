// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import SwiftUI

private let auroraDark = Color(red: 0.04, green: 0.05, blue: 0.09)

private func auroraInteriorPoints(phase: Double) -> [SIMD2<Float>] {
    let drift = Float(0.05)
    func point(_ baseX: Float, _ baseY: Float, _ offset: Double) -> SIMD2<Float> {
        SIMD2(
            baseX + Float(sin(phase + offset)) * drift,
            baseY + Float(cos(phase + offset)) * drift
        )
    }
    return [
        SIMD2(0.0, 0.0), SIMD2(0.5, 0.0), SIMD2(1.0, 0.0),
        SIMD2(0.0, 0.5), point(0.5, 0.5, 0.0), SIMD2(1.0, 0.5),
        SIMD2(0.0, 1.0), SIMD2(0.5, 1.0), SIMD2(1.0, 1.0)
    ]
}

private var auroraColors: [Color] {
    let gold = SponsorTier.gold.glowColor
    let silver = SponsorTier.silver.glowColor
    let bronze = SponsorTier.bronze.glowColor
    func blend(_ color: Color, _ amount: Double) -> Color {
        color.mix(with: auroraDark, by: amount)
    }
    return [
        blend(gold, 0.55), blend(silver, 0.7), blend(bronze, 0.55),
        blend(silver, 0.6), blend(gold, 0.35), blend(bronze, 0.6),
        blend(bronze, 0.55), blend(gold, 0.7), blend(silver, 0.55)
    ]
}

struct AuroraBackdrop: View {
    @Bindable var motionPolicy: MotionPolicy

    var body: some View {
        ZStack {
            auroraDark
            mesh
        }
        .ignoresSafeArea()
    }

    @ViewBuilder private var mesh: some View {
        if motionPolicy.animationsEnabled {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate * 0.12
                MeshGradient(
                    width: 3,
                    height: 3,
                    points: auroraInteriorPoints(phase: phase),
                    colors: auroraColors
                )
            }
        } else {
            MeshGradient(
                width: 3,
                height: 3,
                points: auroraInteriorPoints(phase: 0),
                colors: auroraColors
            )
        }
    }
}
