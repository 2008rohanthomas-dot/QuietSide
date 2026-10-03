import SwiftUI
import MapKit
import UIKit

struct ActiveNavigationView: View {
    let place: Place
    let profile: SensoryProfile
    let locationService: LocationService
    @State private var session: NavigationSession
    @State private var camera: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
    @State private var showEndConfirmation = false
    @State private var environment = EnvironmentStore.shared
    @State private var layers = MapLayerSettings.shared
    @Environment(\.dismiss) private var dismiss

    init(candidate: RouteCandidate, place: Place, profile: SensoryProfile, locationService: LocationService) {
        self.place = place
        self.profile = profile
        self.locationService = locationService
        _session = State(initialValue: NavigationSession(candidate: candidate))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $camera) {
                EnvironmentalMapLayer(store: environment, settings: layers, fieldOpacity: 0.75)
                MapPolyline(session.candidate.route.polyline)
                    .stroke(.white, style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round))
                MapPolyline(session.candidate.route.polyline)
                    .stroke(
                        QSColor.route(session.candidate.kind),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round)
                    )
                UserAnnotation()
                Marker(place.name, coordinate: place.coordinate).tint(QSColor.moss)
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
            .ignoresSafeArea(edges: .bottom)
            .task { await environment.load() }
            .overlay(alignment: .topTrailing) {
                Button {
                    camera = .userLocation(followsHeading: true, fallback: .automatic)
                } label: {
                    Image(systemName: "location.north.fill")
                        .font(.headline)
                        .padding(12)
                        .background(.thickMaterial, in: Circle())
                }
                .padding()
                .accessibilityLabel("Recenter and follow heading")
            }

            VStack(spacing: 12) {
                navigationCard
                Button("End route", role: .destructive) { showEndConfirmation = true }
                    .font(.subheadline.weight(.semibold))
            }
            .padding(16)
        }
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .principal) {
                Label(
                    "\(session.candidate.kind.rawValue) route",
                    systemImage: session.candidate.kind == .calmest ? "leaf.fill" : "bolt.fill"
                )
                .font(.subheadline.weight(.semibold))
            }
        }
        .onAppear {
            locationService.startNavigationUpdates()
            if let location = locationService.latestLocation { session.update(with: location) }
        }
        .onChange(of: locationService.latestLocation?.timestamp) { _, _ in
            guard let location = locationService.latestLocation else { return }
            session.update(with: location)
            if session.arrived { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        }
        .task(id: session.rerouteGeneration) {
            guard session.rerouteGeneration > 0,
                  let location = locationService.latestLocation else { return }
            await session.reroute(from: location, to: place.mapItem, profile: profile)
        }
        .onDisappear { locationService.stop() }
        .confirmationDialog("End this route?", isPresented: $showEndConfirmation) {
            Button("End route", role: .destructive) {
                locationService.stop()
                dismiss()
            }
            Button("Keep walking", role: .cancel) {}
        }
    }

    private var navigationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if session.isRerouting {
                Label("Rerouting from your current position…", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(QSColor.amber)
            }

            HStack(alignment: .top) {
                Image(systemName: instructionSymbol)
                    .font(.title.bold()).foregroundStyle(QSColor.moss)
                    .frame(width: 52, height: 52)
                    .background(QSColor.sage.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 3) {
                    Text(distanceToManeuver).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Text(instruction).font(.title3.bold())
                }
                Spacer()
            }

            ProgressView(value: session.progress?.fractionComplete ?? 0).tint(QSColor.moss)

            if locationService.latestLocation == nil {
                Label("Waiting for an accurate GPS fix", systemImage: "location.circle")
                    .font(.subheadline).foregroundStyle(QSColor.amber)
            } else if case .poor = locationService.quality {
                Label(locationService.quality.label, systemImage: "location.slash.circle")
                    .font(.caption).foregroundStyle(QSColor.amber)
            }

            if session.progress?.isOffRoute == true {
                Label("You appear to be off route", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(QSColor.amber)
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(remainingTime).font(.headline)
                    Text("\(remainingDistance) · to \(place.name)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if session.arrived {
                    Button("Finish") { dismiss() }
                        .font(.headline).foregroundStyle(.white)
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .background(QSColor.moss, in: Capsule())
                } else {
                    Text("LIVE")
                        .font(.caption2.bold()).foregroundStyle(QSColor.moss)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(QSColor.sage.opacity(0.55), in: Capsule())
                }
            }
        }
        .quietCard()
    }

    private var instruction: String {
        if session.arrived { return "You have arrived" }
        return session.currentStep?.instructions.nonEmpty ?? "Continue toward \(place.name)"
    }

    private var instructionSymbol: String {
        if session.arrived { return "checkmark.circle.fill" }
        return "arrow.up"
    }

    private var distanceToManeuver: String {
        guard let distance = session.progress?.distanceToManeuver else { return "Acquiring location" }
        return DistanceText.string(meters: distance)
    }

    private var remainingDistance: String {
        DistanceText.string(meters: session.progress?.remainingDistance ?? session.candidate.route.distance)
    }

    private var remainingTime: String {
        let seconds = session.progress?.remainingTime ?? session.candidate.route.expectedTravelTime
        return "\(max(1, Int(ceil(seconds / 60)))) min"
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
