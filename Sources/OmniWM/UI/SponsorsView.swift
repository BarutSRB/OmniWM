// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

struct Sponsor: Identifiable {
    let id = UUID()
    let name: String
    let githubUsername: String?
    let imageName: String?
    let imageExtension: String?
}

private let sponsors: [Sponsor] = [
    Sponsor(name: "Christopher2K", githubUsername: "Christopher2K", imageName: "christopher2k", imageExtension: "jpg"),
    Sponsor(name: "Aelte", githubUsername: "aelte", imageName: "aelte", imageExtension: "png"),
    Sponsor(name: "captainpryce", githubUsername: "captainpryce", imageName: "captainpryce", imageExtension: "jpg"),
    Sponsor(name: "sgrimee", githubUsername: "sgrimee", imageName: "sgrimee", imageExtension: "jpg"),
    Sponsor(name: "aidansunbury", githubUsername: "aidansunbury", imageName: "aidansunbury", imageExtension: "png"),
    Sponsor(name: "dwstevens", githubUsername: "dwstevens", imageName: "dwstevens", imageExtension: "png"),
    Sponsor(name: "swilson2020", githubUsername: "swilson2020", imageName: "swilson2020", imageExtension: "jpg"),
    Sponsor(name: "Jeff Windsor", githubUsername: "jeffwindsor", imageName: "jeffwindsor", imageExtension: "png"),
    Sponsor(name: "Jason Martin", githubUsername: "jsonMartin", imageName: "jsonmartin", imageExtension: "png"),
    Sponsor(name: "dagi3d", githubUsername: "dagi3d", imageName: "dagi3d", imageExtension: "jpg"),
    Sponsor(name: "Aleksei Gurianov", githubUsername: "Guria", imageName: "guria", imageExtension: "png"),
    Sponsor(name: "Stefan Antoni", githubUsername: nil, imageName: nil, imageExtension: nil),
    Sponsor(name: "Naoki Ikeguchi", githubUsername: "siketyan", imageName: "siketyan", imageExtension: "png"),
    Sponsor(name: "Justin Miller", githubUsername: "incanus", imageName: "incanus", imageExtension: "png"),
    Sponsor(name: "benhaotang", githubUsername: "benhaotang", imageName: "benhaotang", imageExtension: "png"),
    Sponsor(name: "Chris M", githubUsername: "tebriel", imageName: "tebriel", imageExtension: "jpg"),
    Sponsor(name: "marckeelingiv", githubUsername: "marckeelingiv", imageName: "marckeelingiv", imageExtension: "png")
]

struct SponsorsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var motionPolicy: MotionPolicy
    @State private var appeared = false
    let onClose: () -> Void

    private func tier(for index: Int) -> SponsorTier {
        switch index {
        case 0:
            return .gold
        case 1:
            return .silver
        case 2:
            return .bronze
        default:
            return .standard
        }
    }

    private func rankLabel(for index: Int) -> String {
        let rank = index + 1
        let mod100 = rank % 100
        let suffix: String
        if mod100 >= 11 && mod100 <= 13 {
            suffix = "th"
        } else {
            switch rank % 10 {
            case 1:
                suffix = "st"
            case 2:
                suffix = "nd"
            case 3:
                suffix = "rd"
            default:
                suffix = "th"
            }
        }
        return "\(rank)\(suffix)"
    }

    private func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    private var sparkleGradient: LinearGradient {
        LinearGradient(
            colors: [.yellow, .orange],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        VStack(spacing: 18) {
            headerSection

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), spacing: 16)],
                    spacing: 16
                ) {
                    ForEach(Array(sponsors.enumerated()), id: \.element.id) { index, sponsor in
                        SponsorCardView(
                            motionPolicy: motionPolicy,
                            name: sponsor.name,
                            githubUsername: sponsor.githubUsername,
                            imageName: sponsor.imageName,
                            imageExtension: sponsor.imageExtension,
                            tier: tier(for: index),
                            rankLabel: rankLabel(for: index)
                        )
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 6)
            }

            footerSection
        }
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 480, minHeight: 440)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .scaleEffect(appeared ? 1.0 : 0.98)
        .opacity(appeared ? 1.0 : 0.0)
        .onAppear {
            if motionPolicy.animationsEnabled {
                withAnimation(.easeOut(duration: 0.2)) {
                    appeared = true
                }
            } else {
                appeared = true
            }
        }
        .onChange(of: motionPolicy.animationsEnabled) { _, enabled in
            if !enabled {
                appeared = true
            }
        }
    }

    private var headerSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22))
                    .foregroundStyle(sparkleGradient)
                Text("Omni Sponsors")
                    .font(.system(size: 26, weight: .bold))
                Image(systemName: "sparkles")
                    .font(.system(size: 22))
                    .foregroundStyle(sparkleGradient)
            }

            Text("Thank you to our amazing supporters!")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            Button(action: { openURL("https://github.com/sponsors/BarutSRB") }) {
                Label("Become a Sponsor", systemImage: "heart.fill")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(GlassButtonStyle(isProminent: true))
            .accessibilityLabel("Become a sponsor on GitHub")
        }
        .padding(.horizontal, 28)
    }

    private var footerSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button(action: { openURL("https://paypal.me/beacon2024") }) {
                    Text("Sponsor on PayPal")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(GlassButtonStyle())

                Button(action: onClose) {
                    Text("Close")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 80)
                }
                .buttonStyle(GlassButtonStyle())
            }

            Text("Ranks reflect sponsorship order, not donation amounts")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 28)
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
            }) {
                cardContent
            }
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
                .frame(width: 88, height: 88)
                .shadow(
                    color: tier.glowColor.opacity(isAnimating ? 0.8 : 0.5),
                    radius: isAnimating ? 12 : 8
                )

            if let image = avatarImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 76, height: 76)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(.quaternary)
                    .frame(width: 76, height: 76)
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
