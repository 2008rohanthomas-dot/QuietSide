import SwiftUI

struct OnboardingView: View {
    @Binding var profile: SensoryProfile
    let onContinue: () -> Void

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
                        Text("What overwhelms you?")
                            .font(.title3)
                            .foregroundStyle(QSColor.ink.opacity(0.7))
                    }

                    TriggerSelector(triggers: $profile.triggers)

                    Button("Continue", action: onContinue)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(profile.triggers.isEmpty)
                        .opacity(profile.triggers.isEmpty ? 0.5 : 1)
                }
                .padding(24)
                .padding(.top, 12)
            }
        }
    }
}

/// Multi-select list of sensory triggers, shared by onboarding and Settings.
struct TriggerSelector: View {
    @Binding var triggers: Set<SensoryTrigger>

    var body: some View {
        VStack(spacing: 10) {
            ForEach(SensoryTrigger.allCases) { trigger in
                let isOn = triggers.contains(trigger)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if isOn { triggers.remove(trigger) } else { triggers.insert(trigger) }
                    }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: trigger.symbol)
                            .font(.headline)
                            .foregroundStyle(isOn ? .white : QSColor.moss)
                            .frame(width: 38, height: 38)
                            .background(isOn ? QSColor.moss : QSColor.sage.opacity(0.65), in: Circle())
                        Text(trigger.title).font(.headline).foregroundStyle(QSColor.ink)
                        Spacer()
                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isOn ? QSColor.moss : .secondary)
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(isOn ? QSColor.moss : Color.primary.opacity(0.07), lineWidth: isOn ? 2 : 1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }
}
