// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

struct AnimatedBorder: View {
    @Bindable var motionPolicy: MotionPolicy
    let colors: [Color]
    let time: Double

    private var angle: Double {
        motionPolicy.animationsEnabled ? time * 60 : 0
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 22)
            .strokeBorder(
                AngularGradient(
                    gradient: Gradient(colors: colors + [colors[0]]),
                    center: .center,
                    angle: .degrees(angle)
                ),
                lineWidth: 2
            )
    }
}

enum SponsorTier {
    case gold
    case silver
    case bronze
    case standard

    var gradientColors: [Color] {
        switch self {
        case .gold:
            return [
                Color(red: 1.0, green: 0.84, blue: 0.0),
                Color(red: 1.0, green: 0.55, blue: 0.0)
            ]
        case .silver:
            return [
                Color(red: 0.91, green: 0.91, blue: 0.91),
                Color(red: 0.66, green: 0.75, blue: 0.85)
            ]
        case .bronze:
            return [
                Color(red: 0.82, green: 0.41, blue: 0.12),
                Color(red: 0.42, green: 0.24, blue: 0.10)
            ]
        case .standard:
            return [
                Color(red: 0.16, green: 0.62, blue: 0.56),
                Color(red: 0.12, green: 0.44, blue: 0.36)
            ]
        }
    }

    var glowColor: Color {
        switch self {
        case .gold:
            return Color(red: 1.0, green: 0.7, blue: 0.0)
        case .silver:
            return Color(red: 0.6, green: 0.7, blue: 0.85)
        case .bronze:
            return Color(red: 0.75, green: 0.38, blue: 0.12)
        case .standard:
            return Color(red: 0.16, green: 0.62, blue: 0.56)
        }
    }
}

struct SponsorCardView: View {
    @Bindable var motionPolicy: MotionPolicy
    let name: String
    let githubUsername: String?
    let imageName: String?
    let imageExtension: String?
    let creditMessage: String?
    let tier: SponsorTier
    let rankLabel: String

    @State private var isHovered = false

    private var githubURL: URL? {
        guard let githubUsername else { return nil }
        return URL(string: "https://github.com/\(githubUsername)")
    }

    var body: some View {
        linkedCardContent
            .onHover { hovering in
                isHovered = hovering
            }
    }

    @ViewBuilder private var linkedCardContent: some View {
        if let githubURL {
            Button(action: {
                NSWorkspace.shared.open(githubURL)
            }, label: {
                cardContent
            })
            .buttonStyle(.plain)
        } else {
            cardContent
        }
    }

    private var cardContent: some View {
        VStack(spacing: 16) {
            GlowingAvatarView(
                motionPolicy: motionPolicy,
                imageName: imageName,
                imageExtension: imageExtension,
                tier: tier
            )

            VStack(spacing: 4) {
                Text(name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .allowsTightening(true)

                profileLabel
            }

            Text(rankLabel)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: tier.gradientColors,
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: tier.glowColor.opacity(isHovered ? 0.3 : 0.1), radius: isHovered ? 12 : 6)
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(motionPolicy.animationsEnabled ? .easeOut(duration: 0.15) : nil, value: isHovered)
    }

    @ViewBuilder private var profileLabel: some View {
        if let githubUsername {
            HStack(spacing: 4) {
                Image(systemName: "link")
                    .font(.system(size: 11))
                Text("@\(githubUsername)")
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .allowsTightening(true)
            }
            .foregroundStyle(.secondary)
        } else if let creditMessage {
            HStack(spacing: 4) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                Text(creditMessage)
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .allowsTightening(true)
            }
            .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 11))
                Text("GitHub profile unknown")
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .allowsTightening(true)
            }
            .foregroundStyle(.secondary)
        }
    }
}

struct GlowingAvatarView: View {
    @Bindable var motionPolicy: MotionPolicy
    let imageName: String?
    let imageExtension: String?
    let tier: SponsorTier
    var ringSize: CGFloat = 88

    @State private var isAnimating = false

    private var avatarImage: NSImage? {
        guard let imageName,
              let imageExtension,
              let url = Bundle.module.url(forResource: imageName, withExtension: imageExtension),
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }
        return image
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    LinearGradient(
                        colors: tier.gradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 4
                )
                .frame(width: ringSize, height: ringSize)
                .shadow(
                    color: tier.glowColor.opacity(isAnimating ? 0.8 : 0.5),
                    radius: isAnimating ? 12 : 8
                )

            if let image = avatarImage {
                Image(nsImage: image)
                    .resizable().scaledToFill()
                    .frame(width: ringSize - 12, height: ringSize - 12)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(.quaternary)
                    .frame(width: ringSize - 12, height: ringSize - 12)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .onAppear {
            updateAnimationState()
        }
        .onChange(of: motionPolicy.animationsEnabled) { _, _ in
            updateAnimationState()
        }
    }

    private func updateAnimationState() {
        guard motionPolicy.animationsEnabled, tier != .standard else {
            isAnimating = false
            return
        }

        isAnimating = false
        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
            isAnimating = true
        }
    }
}
