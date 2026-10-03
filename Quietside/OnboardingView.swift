import SwiftUI

struct OnboardingView: View {
    @Binding var profile: SensoryProfile
    let onContinue: () -> Void

    private let items: [(String, String, String, WritableKeyPath<SensoryProfile, SensitivityLevel>)] = [
        ("Noise", "Street noise and sudden sounds", "speaker.wave.2.fill", \.noise),
        ("Crowds", "Busy sidewalks and packed places", "person.2.fill", \.crowds),
        ("Traffic", "Major roads and crossings", "car.fill", \.traffic),
        ("Lighting", "Harsh or flashing lights", "lightbulb.fill", \.lighting)
    ]

    var body: some View {
        ZStack {
            LinearGradient(colors: [QSColor.cream, QSColor.sage.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "leaf.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(QSColor.moss)
                            .accessibilityHidden(true)
                        Text("Find your quieter way.")
                            .font(.largeTitle.bold())
                            .foregroundStyle(QSColor.ink)
                        Text("Tell Quietside what affects you. We’ll use it to compare every route and place.")
                            .font(.title3)
                            .foregroundStyle(QSColor.ink.opacity(0.7))
                    }

                    VStack(spacing: 12) {
                        ForEach(items, id: \.0) { name, subtitle, icon, keyPath in
                            SensitivityRow(
                                name: name,
                                subtitle: subtitle,
                                icon: icon,
                                level: Binding(
                                    get: { profile[keyPath: keyPath] },
                                    set: { profile[keyPath: keyPath] = $0 }
                                )
                            )
                        }
                    }

                    VStack(spacing: 12) {
                        Button("Create my calm profile", action: onContinue)
                            .buttonStyle(PrimaryButtonStyle())
                        Text("You can change this anytime in Settings.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .padding(.top, 12)
            }
        }
    }
}

private struct SensitivityRow: View {
    let name: String
    let subtitle: String
    let icon: String
    @Binding var level: SensitivityLevel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.headline)
                    .foregroundStyle(QSColor.moss)
                    .frame(width: 34, height: 34)
                    .background(QSColor.sage.opacity(0.65), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker(name, selection: $level) {
                ForEach(SensitivityLevel.allCases) { option in Text(option.title).tag(option) }
            }
            .pickerStyle(.segmented)
        }
        .quietCard()
    }
}
