import SwiftUI

struct ContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var profile = SensoryProfile.load()
    @State private var locationService = LocationService()

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                MainTabView(profile: $profile, locationService: locationService) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        hasCompletedOnboarding = false
                    }
                }
            } else {
                OnboardingView(profile: $profile) {
                    profile.save()
                    withAnimation(.easeInOut(duration: 0.3)) {
                        hasCompletedOnboarding = true
                    }
                }
            }
        }
        .tint(QSColor.moss)
    }
}

private struct MainTabView: View {
    @Binding var profile: SensoryProfile
    let locationService: LocationService
    let resetOnboarding: () -> Void

    var body: some View {
        TabView {
            HomeView(profile: profile, locationService: locationService)
                .tabItem { Label("Explore", systemImage: "map.fill") }

            MeasureView(locationService: locationService)
                .tabItem { Label("Measure", systemImage: "waveform") }

            SettingsView(profile: $profile, resetOnboarding: resetOnboarding)
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
        }
    }
}

#Preview { ContentView() }
