import SwiftUI

enum QSColor {
    static let moss = Color(red: 0.14, green: 0.43, blue: 0.34)
    static let mossDark = Color(red: 0.08, green: 0.28, blue: 0.22)
    static let sage = Color(red: 0.79, green: 0.87, blue: 0.80)
    static let cream = Color(red: 0.96, green: 0.95, blue: 0.91)
    static let ink = Color(red: 0.09, green: 0.12, blue: 0.11)
    static let amber = Color(red: 0.84, green: 0.55, blue: 0.20)
    static let coral = Color(red: 0.79, green: 0.32, blue: 0.26)
    static let routeFast = Color(red: 0.24, green: 0.40, blue: 0.63)

    static let routeAlternative = Color(red: 0.42, green: 0.47, blue: 0.53)

    static func route(_ kind: RouteKind) -> Color {
        switch kind {
        case .calmest: moss
        case .fastest: routeFast
        case .alternative: routeAlternative
        }
    }

    static func level(_ level: SensoryLevel) -> Color {
        switch level {
        case .calm: moss
        case .moderate: amber
        case .high: coral
        }
    }
}

struct QuietCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.06), radius: 18, y: 8)
    }
}

extension View {
    func quietCard() -> some View { modifier(QuietCardModifier()) }
}

struct CalmBadge: View {
    let score: Double?

    var body: some View {
        if let score {
            let level = SensoryLevel(score: score)
            Label(level.rawValue, systemImage: level == .calm ? "leaf.fill" : "circle.lefthalf.filled")
                .font(.caption.weight(.semibold))
                .foregroundStyle(QSColor.level(level))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(QSColor.level(level).opacity(0.12), in: Capsule())
                .accessibilityLabel("Known-signal exposure: \(level.rawValue)")
        } else {
            Label("Unknown", systemImage: "questionmark.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(QSColor.moss.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

struct SensoryEvidenceList: View {
    let sensory: RouteSensory

    var body: some View {
        VStack(spacing: 12) {
            ForEach(sensory.signals) { signal in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: signal.symbol)
                            .foregroundStyle(signal.level.map(QSColor.level) ?? Color.secondary)
                            .frame(width: 22)
                        Text(signal.title).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(signal.displayValue)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(signal.level.map(QSColor.level) ?? Color.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    Text(signal.detail).font(.caption2).foregroundStyle(.secondary)
                    if let source = signal.source {
                        Link(destination: source.url) {
                            Label("\(source.publisher) · \(signal.kind.rawValue)", systemImage: "arrow.up.right.square")
                                .font(.caption2.weight(.medium))
                        }
                    }
                }
                if signal.id != sensory.signals.last?.id { Divider() }
            }
        }
    }
}
