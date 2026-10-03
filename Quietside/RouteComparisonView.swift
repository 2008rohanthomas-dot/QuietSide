import SwiftUI
import MapKit

struct RouteComparisonView: View {
    let place: Place
    let profile: SensoryProfile

    @State private var candidates: [RouteCandidate] = []
    @State private var selectedKind: RouteKind = .calmest
    @State private var camera: MapCameraPosition = .region(CampusOrigin.region)
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var environment = EnvironmentStore.shared
    @State private var layers = MapLayerSettings.shared

    private var selected: RouteCandidate? {
        candidates.first { $0.kind == selectedKind } ?? candidates.first
    }

    private var fastest: RouteCandidate? { candidates.first { $0.kind == .fastest } }

    var body: some View {
        VStack(spacing: 0) {
            routeMap

            ScrollView {
                VStack(spacing: 12) {
                    if isLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Finding routes").font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    } else if let errorMessage {
                        ContentUnavailableView {
                            Label("No walking route", systemImage: "figure.walk")
                        } description: {
                            Text(errorMessage)
                        } actions: {
                            Button("Try again") { Task { await calculateRoutes() } }
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        ForEach(candidates) { candidate in
                            RouteOptionCard(
                                candidate: candidate,
                                fastest: fastest,
                                layer: layers.layer,
                                selected: selected?.kind == candidate.kind
                            ) {
                                withAnimation(.easeInOut(duration: 0.2)) { selectedKind = candidate.kind }
                            }
                        }

                        if let selected {
                            NavigationLink {
                                ActiveNavigationView(candidate: selected, place: place)
                            } label: {
                                Label("Start \(selected.kind.rawValue)", systemImage: "figure.walk")
                            }
                            .buttonStyle(PrimaryButtonStyle(color: QSColor.route(selected.kind)))
                            .padding(.top, 4)
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(QSColor.cream.opacity(0.38))
        .navigationTitle(place.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: environment.snapshot?.activeEvents.map(\.id)) { await calculateRoutes() }
    }

    private var routeMap: some View {
        Map(position: $camera) {
            EnvironmentalMapLayer(store: environment, settings: layers)
            ForEach(candidates.filter { $0.kind != selected?.kind }) { candidate in
                ExposureRouteLine(candidate: candidate, layer: layers.layer, selected: false)
            }
            if let selected {
                ExposureRouteLine(candidate: selected, layer: layers.layer)
            }
            Annotation("CIF", coordinate: CampusOrigin.cif.coordinate, anchor: .center) { OriginMarker() }
            Marker(place.name, coordinate: place.coordinate).tint(QSColor.moss)
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .frame(height: 360)
        .overlay(alignment: .topLeading) {
            LayerPicker(settings: layers).padding(10)
        }
        .overlay(alignment: .topTrailing) {
            MapLayerMenu(settings: layers).padding(10)
        }
    }

    private func calculateRoutes() async {
        isLoading = candidates.isEmpty
        errorMessage = nil
        do {
            let result = try await RouteService().candidates(to: place.mapItem, profile: profile)
            candidates = result
            var rect = MKMapRect.null
            for candidate in result { rect = rect.union(candidate.route.polyline.boundingMapRect) }
            if !rect.isNull {
                let padding = max(rect.size.width, rect.size.height) * 0.2
                camera = .rect(rect.insetBy(dx: -padding, dy: -padding))
            }
        } catch {
            if candidates.isEmpty { errorMessage = "Apple Maps couldn't find a walking route from CIF to \(place.name)." }
        }
        isLoading = false
    }
}

private struct RouteOptionCard: View {
    let candidate: RouteCandidate
    let fastest: RouteCandidate?
    let layer: EnvironmentalLayer
    let selected: Bool
    let action: () -> Void

    private var exposure: RouteExposure { candidate.exposure }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Label(candidate.kind.rawValue, systemImage: candidate.kind.symbol)
                        .font(.title3.bold())
                        .foregroundStyle(QSColor.route(candidate.kind))
                    Spacer()
                    Text("\(candidate.minutes) min").font(.title3.bold())
                    Text(String(format: "%.1f mi", candidate.distanceMiles))
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Metric(title: "Noise", value: "\(Int(exposure.averageNoiseDb.rounded())) dB",
                           level: ExposureLevel((exposure.averageNoiseDb - EnvironmentalWeights.ambientNoiseDb) / EnvironmentalWeights.noiseRangeDb))
                    Metric(title: "Crowd", value: ExposureLevel(exposure.averageCrowd).rawValue, level: ExposureLevel(exposure.averageCrowd))
                    Metric(title: "Traffic", value: ExposureLevel(exposure.averageTraffic).rawValue, level: ExposureLevel(exposure.averageTraffic))
                    Metric(title: "Signals", value: "\(exposure.intersections.count)",
                           level: exposure.intersections.count > 3 ? .high : exposure.intersections.count > 1 ? .moderate : .low)
                }

                ExposureStrip(segments: exposure.segments, layer: layer)

                if !exposure.eventIds.isEmpty,
                   let event = CampusEventCatalog.all.first(where: { exposure.eventIds.contains($0.id) }) {
                    Label("Passes \(event.name)", systemImage: event.symbol)
                        .font(.caption.weight(.semibold)).foregroundStyle(ExposurePalette.event)
                }

                if candidate.kind == .calmest {
                    if candidate.matchesFastest {
                        Label("Fastest is also the calmest", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(QSColor.mossDark)
                    } else if let fastest {
                        Text(RouteComparison.reasons(calm: exposure, fastest: fastest.exposure).joined(separator: " · "))
                            .font(.caption.weight(.semibold)).foregroundStyle(QSColor.mossDark)
                    }
                }
            }
            .quietCard()
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(selected ? QSColor.route(candidate.kind) : Color.clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct Metric: View {
    let title: String
    let value: String
    let level: ExposureLevel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.bold)).foregroundStyle(QSColor.level(level))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
