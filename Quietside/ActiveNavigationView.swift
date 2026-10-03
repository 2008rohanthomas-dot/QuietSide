import SwiftUI
import MapKit
import UIKit

struct ActiveNavigationView: View {
    let place: Place
    @State private var session: NavigationSession
    @State private var camera: MapCameraPosition
    @State private var following = true
    @State private var environment = EnvironmentStore.shared
    @State private var layers = MapLayerSettings.shared
    @Environment(\.dismiss) private var dismiss

    init(candidate: RouteCandidate, place: Place) {
        self.place = place
        _session = State(initialValue: NavigationSession(candidate: candidate))
        _camera = State(initialValue: .camera(MapCamera(centerCoordinate: CampusOrigin.cif.coordinate, distance: 650)))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $camera) {
                EnvironmentalMapLayer(store: environment, settings: layers, fieldOpacity: 0.75)
                ExposureRouteLine(candidate: session.candidate, layer: layers.layer)
                Annotation("CIF", coordinate: CampusOrigin.cif.coordinate) {
                    Circle().fill(.white).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(QSColor.routeFast, lineWidth: 3))
                }
                .annotationTitles(.hidden)
                Annotation("You", coordinate: session.position, anchor: .center) { OriginMarker() }
                    .annotationTitles(.hidden)
                Marker(place.name, coordinate: place.coordinate).tint(QSColor.moss)
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in following = false })
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) {
                HStack(alignment: .top) {
                    LayerPicker(settings: layers)
                    Spacer()
                    if !following {
                        Button {
                            following = true
                            follow()
                        } label: { MapControlIcon(systemImage: "location.fill") }
                        .accessibilityLabel("Recenter")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            navigationCard.padding(16)
        }
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .principal) {
                Label(session.candidate.kind.rawValue, systemImage: session.candidate.kind.symbol)
                    .font(.subheadline.weight(.semibold))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("End") {
                    session.stop()
                    dismiss()
                }
                .fontWeight(.semibold)
            }
        }
        .onAppear { session.start() }
        .onDisappear { session.stop() }
        .onChange(of: session.travelled) { _, _ in if following { follow() } }
        .onChange(of: session.arrived) { _, arrived in
            if arrived { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        }
    }

    private func follow() {
        camera = .camera(MapCamera(centerCoordinate: session.position, distance: 650))
    }

    private var navigationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: session.arrived ? "checkmark" : maneuverSymbol)
                    .font(.title2.bold()).foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(QSColor.route(session.candidate.kind), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 2) {
                    if !session.arrived, let step = session.currentStep {
                        Text(DistanceText.string(meters: step.remaining))
                            .font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                    }
                    Text(instruction).font(.title3.bold()).lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            ProgressView(value: session.fractionComplete).tint(QSColor.route(session.candidate.kind))

            if let sample = environment.snapshot?.sample(at: session.position) {
                HStack(spacing: 8) {
                    LiveMetric(symbol: "speaker.wave.2.fill", text: "\(Int(sample.noiseDb.rounded())) dB",
                               value: (sample.noiseDb - EnvironmentalWeights.ambientNoiseDb) / EnvironmentalWeights.noiseRangeDb)
                    LiveMetric(symbol: "person.3.fill", text: ExposureLevel(sample.crowdLevel).rawValue, value: sample.crowdLevel)
                    LiveMetric(symbol: "car.fill", text: ExposureLevel(sample.trafficLevel).rawValue, value: sample.trafficLevel)
                }
                if let event = CampusEventCatalog.all.first(where: { sample.activeEventIds.contains($0.id) }) {
                    Label("Near \(event.name)", systemImage: event.symbol)
                        .font(.caption.weight(.semibold)).foregroundStyle(ExposurePalette.event)
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(max(1, Int(ceil(session.remainingTime / 60)))) min").font(.headline)
                    Text(DistanceText.string(meters: session.remainingDistance))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if session.arrived {
                    Button("Done") { dismiss() }
                        .font(.headline).foregroundStyle(.white)
                        .padding(.horizontal, 22).padding(.vertical, 11)
                        .background(QSColor.moss, in: Capsule())
                } else {
                    Button {
                        session.togglePause()
                    } label: {
                        Image(systemName: session.isPaused ? "play.fill" : "pause.fill")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                            .background(Color.primary.opacity(0.07), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(session.isPaused ? "Resume" : "Pause")
                }
            }
        }
        .quietCard()
    }

    private var instruction: String {
        if session.arrived { return "Arrived at \(place.name)" }
        let text = session.currentStep?.step.instructions ?? ""
        return text.isEmpty ? "Head toward \(place.name)" : text
    }

    private var maneuverSymbol: String {
        let text = (session.currentStep?.step.instructions ?? "").lowercased()
        if text.contains("left") { return "arrow.turn.up.left" }
        if text.contains("right") { return "arrow.turn.up.right" }
        if text.contains("arrive") || text.contains("destination") { return "mappin" }
        return "arrow.up"
    }
}

private struct LiveMetric: View {
    let symbol: String
    let text: String
    let value: Double

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.caption2)
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundStyle(QSColor.ink)
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(ExposurePalette.color(for: value).opacity(0.35), in: Capsule())
    }
}
