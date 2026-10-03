import SwiftUI

struct SettingsView: View {
    @Binding var profile: SensoryProfile
    let resetOnboarding: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your triggers").font(.headline)
                        TriggerSelector(triggers: $profile.triggers)
                        Text("Calmest routes avoid these first.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Button("Run onboarding again", action: resetOnboarding)
                        .font(.subheadline.weight(.semibold))
                }
                .padding(20)
            }
            .background(QSColor.cream.opacity(0.38))
            .navigationTitle("Triggers")
        }
    }
}
