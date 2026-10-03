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

    static func route(_ kind: RouteKind) -> Color {
        switch kind {
        case .calmest: moss
        case .fastest: routeFast
        }
    }

    static func level(_ level: ExposureLevel) -> Color {
        switch level {
        case .low: moss
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

struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = QSColor.moss

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(color.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}
