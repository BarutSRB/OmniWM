import AppKit
import SwiftUI

struct Sponsor: Identifiable {
    let id = UUID()
    let name: String
    let githubUsername: String
    let imageName: String
    let imageExtension: String
}

private let sponsors: [Sponsor] = [
    Sponsor(name: "Christopher2K", githubUsername: "Christopher2K", imageName: "christopher2k", imageExtension: "jpg"),
    Sponsor(name: "Aelte", githubUsername: "aelte", imageName: "aelte", imageExtension: "png"),
    Sponsor(name: "captainpryce", githubUsername: "captainpryce", imageName: "captainpryce", imageExtension: "jpg"),
    Sponsor(name: "sgrimee", githubUsername: "sgrimee", imageName: "sgrimee", imageExtension: "jpg"),
    Sponsor(name: "aidansunbury", githubUsername: "aidansunbury", imageName: "aidansunbury", imageExtension: "png"),
    Sponsor(name: "dwstevens", githubUsername: "dwstevens", imageName: "dwstevens", imageExtension: "png")
]

struct SponsorsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var appeared = false
    @State private var currentIndex = 0
    let onClose: () -> Void

    private let visibleCount = 1

    private var canNavigateLeft: Bool {
        currentIndex > 0
    }

    private var canNavigateRight: Bool {
        currentIndex < sponsors.count - visibleCount
    }

    private var visibleSponsors: ArraySlice<Sponsor> {
        let endIndex = min(currentIndex + visibleCount, sponsors.count)
        return sponsors[currentIndex..<endIndex]
    }

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

    private func navigateLeft() {
        guard canNavigateLeft else { return }
        let animate = AppDelegate.sharedSettings?.animationsEnabled ?? true
        if animate {
            withAnimation(.easeInOut(duration: 0.3)) {
                currentIndex -= 1
            }
        } else {
            currentIndex -= 1
        }
    }

    private func navigateRight() {
        guard canNavigateRight else { return }
        let animate = AppDelegate.sharedSettings?.animationsEnabled ?? true
        if animate {
            withAnimation(.easeInOut(duration: 0.3)) {
                currentIndex += 1
            }
        } else {
            currentIndex += 1
        }
    }

    private var leftArrowButton: some View {
        Button(action: navigateLeft) {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(GlassButtonStyle())
        .opacity(canNavigateLeft ? 1.0 : 0.3)
        .disabled(!canNavigateLeft)
    }

    private var rightArrowButton: some View {
        Button(action: navigateRight) {
            Image(systemName: "chevron.right")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(GlassButtonStyle())
        .opacity(canNavigateRight ? 1.0 : 0.3)
        .disabled(!canNavigateRight)
    }

    var body: some View {
        VStack(spacing: 20) {
            headerSection

            HStack(spacing: 16) {
                if sponsors.count > visibleCount {
                    leftArrowButton
                }

                HStack(spacing: 0) {
                    ForEach(Array(Array(visibleSponsors).enumerated()), id: \.element.id) { offset, sponsor in
                        SponsorCardView(
                            name: sponsor.name,
                            githubUsername: sponsor.githubUsername,
                            imageName: sponsor.imageName,
                            imageExtension: sponsor.imageExtension,
                            tier: tier(for: currentIndex + offset),
                            rankLabel: rankLabel(for: currentIndex + offset)
                        )
                        .frame(maxWidth: 360)
                    }
                }

                if sponsors.count > visibleCount {
                    rightArrowButton
                }
            }
            .padding(.horizontal, 24)

            VStack(spacing: 8) {
                Button(action: onClose) {
                    Text("Close")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 100)
                }
                .buttonStyle(GlassButtonStyle())

                Text("Ranks reflect sponsorship order, not donation amounts")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(32)
        .frame(width: 700, height: 400)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .scaleEffect(appeared ? 1.0 : 0.95)
        .opacity(appeared ? 1.0 : 0.0)
        .onAppear {
            if AppDelegate.sharedSettings?.animationsEnabled ?? true {
                withAnimation(.easeOut(duration: 0.2)) {
                    appeared = true
                }
            } else {
                appeared = true
            }
        }
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 24))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.yellow, .orange],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("Omni Sponsors")
                    .font(.system(size: 28, weight: .bold))
                Image(systemName: "sparkles")
                    .font(.system(size: 24))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.yellow, .orange],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            Text("Thank you to our amazing supporters!")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
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
            return [Color(red: 1.0, green: 0.84, blue: 0.0),
                    Color(red: 1.0, green: 0.55, blue: 0.0)]
        case .silver:
            return [Color(red: 0.91, green: 0.91, blue: 0.91),
                    Color(red: 0.66, green: 0.75, blue: 0.85)]
        case .bronze:
            return [Color(red: 0.82, green: 0.41, blue: 0.12),
                    Color(red: 0.42, green: 0.24, blue: 0.10)]
        case .standard:
            return [Color(red: 0.16, green: 0.62, blue: 0.56),
                    Color(red: 0.12, green: 0.44, blue: 0.36)]
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
    let name: String
    let githubUsername: String
    let imageName: String
    let imageExtension: String
    let tier: SponsorTier
    let rankLabel: String

    @State private var isHovered = false

    private var githubURL: URL? {
        URL(string: "https://github.com/\(githubUsername)")
    }

    var body: some View {
        Button(action: {
            if let url = githubURL {
                NSWorkspace.shared.open(url)
            }
        }) {
            VStack(spacing: 16) {
                GlowingAvatarView(
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
            .animation(
                (AppDelegate.sharedSettings?.animationsEnabled ?? true) ? .easeOut(duration: 0.15) : nil,
                value: isHovered
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct GlowingAvatarView: View {
    let imageName: String
    let imageExtension: String
    let tier: SponsorTier

    @State private var isAnimating = false

    private var avatarImage: NSImage? {
        guard let url = Bundle.module.url(forResource: imageName, withExtension: imageExtension),
              let image = NSImage(contentsOf: url) else {
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
            if AppDelegate.sharedSettings?.animationsEnabled ?? true {
                withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                    isAnimating = true
                }
            }
        }
    }
}
