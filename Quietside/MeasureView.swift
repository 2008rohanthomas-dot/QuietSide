import SwiftUI
import AVFAudio
import CoreLocation
import Observation
import UIKit

@MainActor
@Observable
final class AudioMeterModel {
    enum State { case ready, requesting, measuring, result, denied, failed(String) }

    var state: State = .ready
    var secondsRemaining = 5
    var liveLevel: Double = 0
    var resultDBFS: Double = -45
    var saved = false

    private let engine = AVAudioEngine()
    private var readings: [Double] = []

    func start() async {
        saved = false
        state = .requesting
        let granted = await requestPermission()
        guard granted else { state = .denied; return }

        do {
            readings.removeAll()
            secondsRemaining = 5
            liveLevel = 0
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true)

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw NSError(domain: "QuietsideAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input is available on this device."])
            }

            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let channel = buffer.floatChannelData?[0] else { return }
                let frames = Int(buffer.frameLength)
                guard frames > 0 else { return }
                var sum: Float = 0
                for index in 0..<frames { sum += channel[index] * channel[index] }
                let rms = sqrt(sum / Float(frames))
                let db = 20 * log10(max(Double(rms), 0.000_001))
                Task { @MainActor in self?.record(db: db) }
            }

            try engine.start()
            state = .measuring
            for remaining in stride(from: 5, through: 1, by: -1) {
                secondsRemaining = remaining
                try await Task.sleep(for: .seconds(1))
            }
            finish()
        } catch {
            stopEngine()
            state = .failed(error.localizedDescription)
        }
    }

    func reset() { stopEngine(); state = .ready; saved = false; liveLevel = 0 }

    func save(at location: CLLocation?) {
        let observation = SoundObservation(
            id: UUID(),
            createdAt: Date(),
            dbFS: resultDBFS,
            latitude: location?.coordinate.latitude,
            longitude: location?.coordinate.longitude,
            horizontalAccuracy: location?.horizontalAccuracy
        )
        var observations: [SoundObservation] = []
        if let data = UserDefaults.standard.data(forKey: "localSoundObservations"),
           let decoded = try? JSONDecoder().decode([SoundObservation].self, from: data) {
            observations = decoded
        }
        observations.append(observation)
        observations = Array(observations.suffix(100))
        if let data = try? JSONEncoder().encode(observations) {
            UserDefaults.standard.set(data, forKey: "localSoundObservations")
        }
        saved = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func record(db: Double) {
        readings.append(db)
        liveLevel = max(0.03, min(1, (db + 65) / 55))
    }

    private func finish() {
        stopEngine()
        let sorted = readings.sorted()
        if sorted.isEmpty {
            resultDBFS = -45
        } else {
            let trim = min(sorted.count / 10, 8)
            let slice = sorted.dropFirst(trim).dropLast(trim)
            resultDBFS = slice.isEmpty ? sorted.reduce(0, +) / Double(sorted.count) : slice.reduce(0, +) / Double(slice.count)
        }
        state = .result
    }

    private func stopEngine() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

struct MeasureView: View {
    let locationService: LocationService
    @State private var model = AudioMeterModel()

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [QSColor.cream, QSColor.sage.opacity(0.42)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 26) {
                        VStack(spacing: 8) {
                            Text("Measure this place").font(.largeTitle.bold())
                            Text("Five seconds helps estimate how this spot feels right now.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        meter
                        VStack(alignment: .leading, spacing: 14) {
                            Label("Audio stays on your iPhone", systemImage: "lock.shield.fill").font(.headline)
                Text("Quietside calculates a relative sound level locally. Raw audio is never saved or uploaded. Saved readings remain on this device and are not yet used for route scores. Results are approximate—not medical or regulatory measurements.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .quietCard()
                        controls
                    }
                    .padding(22).padding(.top, 18)
                }
            }
            .navigationTitle("Contribute").navigationBarTitleDisplayMode(.inline)
        }
    }

    private var meter: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 18)
            Circle().trim(from: 0, to: meterProgress)
                .stroke(QSColor.moss, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90)).animation(.easeOut(duration: 0.18), value: meterProgress)
            VStack(spacing: 8) {
                Image(systemName: meterSymbol).font(.system(size: 38, weight: .semibold)).foregroundStyle(QSColor.moss)
                Text(meterTitle).font(.title2.bold())
                Text(meterSubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
            }
            .padding(24)
        }
        .frame(width: 235, height: 235).padding(.vertical, 8).accessibilityElement(children: .combine)
    }

    private var meterProgress: Double {
        switch model.state {
        case .measuring: model.liveLevel
        case .result: max(0.08, min(1, (model.resultDBFS + 65) / 55))
        default: 0.06
        }
    }

    private var meterSymbol: String {
        switch model.state {
        case .measuring: "waveform"
        case .result: "checkmark"
        case .denied, .failed: "exclamationmark.triangle"
        default: "mic.fill"
        }
    }

    private var meterTitle: String {
        switch model.state {
        case .requesting: "Preparing…"
        case .measuring: "\(model.secondsRemaining)"
        case .result: model.saved ? "Saved locally" : soundLabel
        case .denied: "Microphone off"
        case .failed: "Couldn’t measure"
        case .ready: "Ready"
        }
    }

    private var meterSubtitle: String {
        switch model.state {
        case .measuring: "Hold still and stay quiet"
        case .result: model.saved ? "Stored on this iPhone" : String(format: "Relative reading %.0f dBFS", model.resultDBFS)
        case .denied: "Enable access in Settings"
        case .failed(let message): message
        default: "Tap below to begin"
        }
    }

    private var soundLabel: String {
        if model.resultDBFS < -48 { return "Quiet" }
        if model.resultDBFS < -28 { return "Moderate" }
        return "Loud"
    }

    @ViewBuilder
    private var controls: some View {
        switch model.state {
        case .ready, .failed, .denied:
            Button { Task { await model.start() } } label: { Label("Measure sound for 5 seconds", systemImage: "waveform") }
                .buttonStyle(PrimaryButtonStyle())
        case .requesting, .measuring:
            Button("Measuring…") {}.buttonStyle(PrimaryButtonStyle()).disabled(true).opacity(0.65)
        case .result:
            if model.saved {
                Button("Measure again") { model.reset() }.buttonStyle(PrimaryButtonStyle())
            } else {
                VStack(spacing: 12) {
                    Button("Save on this iPhone") { model.save(at: locationService.latestLocation) }
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Discard") { model.reset() }.foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct SoundObservation: Codable {
    let id: UUID
    let createdAt: Date
    let dbFS: Double
    let latitude: Double?
    let longitude: Double?
    let horizontalAccuracy: Double?
}
