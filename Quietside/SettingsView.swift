import SwiftUI

struct SettingsView: View {
    @Binding var profile: SensoryProfile
    let resetOnboarding: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(profileRows, id: \.0) { title, icon, keyPath in
                        Picker(selection: Binding(
                            get: { profile[keyPath: keyPath] },
                            set: { profile[keyPath: keyPath] = $0 }
                        )) {
                            ForEach(SensitivityLevel.allCases) { level in Text(level.title).tag(level) }
                        } label: { Label(title, systemImage: icon) }
                    }
                } header: { Text("Sensory profile") }
                footer: { Text("Quietside applies these weights only to dimensions that have defensible evidence. Unknown signals are excluded, never treated as zero.") }

                Section("Data & privacy") {
                    Label("Sound is processed on-device", systemImage: "lock.shield")
                    Label("Raw audio is never uploaded", systemImage: "waveform.slash")
                    Label("Missing official data is shown as Unknown", systemImage: "questionmark.circle")
                }

                Section("Official sources") {
                    Link("Champaign streetlights", destination: OfficialDataRepository.champaignStreetlights.url)
                    Link("Champaign traffic signals", destination: OfficialDataRepository.champaignSignals.url)
                    Link("UIUC Course Explorer API", destination: OfficialDataRepository.courseExplorer.url)
                    Link("US DOT transportation noise map", destination: OfficialDataRepository.nationalNoiseMap.url)
                }

                Section {
                    Button("Run onboarding again", action: resetOnboarding)
                    Button("Save profile") { profile.save() }
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Prototype note").font(.headline)
                        Text("Quietside uses real Apple walking routes and labels official infrastructure separately from derived estimates. Around Campustown, traffic and activity exposure are relative estimates modelled from annual traffic volumes, venue locations, and major crossings, not live decibel or crowd readings. It does not guarantee a medically safe route.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Settings")
            .onChange(of: profile) { _, newValue in newValue.save() }
        }
    }

    private var profileRows: [(String, String, WritableKeyPath<SensoryProfile, SensitivityLevel>)] {
        [("Noise", "speaker.wave.2", \.noise), ("Crowds", "person.2", \.crowds), ("Traffic", "car", \.traffic), ("Lighting", "lightbulb", \.lighting)]
    }
}
