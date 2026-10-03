import SwiftUI

struct ContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var profile = SensoryProfile.load()
    @State private var environment = EnvironmentStore.shared

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                MainTabView(profile: $profile) {
                    withAnimation(.easeInOut(duration: 0.25)) { hasCompletedOnboarding = false }
                }
            } else {
                OnboardingView(profile: $profile) {
                    profile.save()
                    withAnimation(.easeInOut(duration: 0.3)) { hasCompletedOnboarding = true }
                }
            }
        }
        .tint(QSColor.moss)
        .task { await environment.start() }
        .onChange(of: profile, initial: true) { _, newValue in
            newValue.save()
            environment.update(weights: newValue.weights)
        }
    }
}

private struct MainTabView: View {
    @Binding var profile: SensoryProfile
    let resetOnboarding: () -> Void

    var body: some View {
        TabView {
            HomeView(profile: profile)
                .tabItem { Label("Explore", systemImage: "map.fill") }

            SettingsView(profile: $profile, resetOnboarding: resetOnboarding)
                .tabItem { Label("Triggers", systemImage: "slider.horizontal.3") }
        }
    }
}

#Preview { ContentView() }
