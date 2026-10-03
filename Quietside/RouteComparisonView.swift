import SwiftUI
import MapKit

struct RouteComparisonView: View {
    let place: Place
    let origin: CLLocation
    let profile: SensoryProfile
    let locationService: LocationService

    @State private var candidates: [RouteCandidate] = []
    @State private var selectedID: UUID?
    @State private var camera: MapCameraPosition = .automatic
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var environment = EnvironmentStore.shared
    @State private var layers = MapLayerSettings.shared

    private var selectedRoute: RouteCandidate? {
        candidates.first(where: { $0.id == selectedID }) ?? candidates.first
    }

    /// Selected route draws last so it always sits on top.
    private var drawOrder: [RouteCandidate] {
        candidates.filter { $0.id != selectedRoute?.id } + candidates.filter { $0.id == selectedRoute?.id }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                routeMap

                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Calculating real walking routes…").font(.headline)
                        Text("Then checking traffic, activity, and crossings near each path.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .quietCard()
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Route unavailable", systemImage: "map.fill")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try again", action: loadRoutes).buttonStyle(.borderedProminent)
                    }
                } else {
                    header

                    ForEach(candidates) { candidate in
                        RouteOptionCard(
                            candidate: candidate,
                            profile: profile,
                            selected: selectedRoute?.id == candidate.id
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) { selectedID = candidate.id }
                        }
                    }

                    if let selectedRoute {
                        NavigationLink {
                            ActiveNavigationView(
                                candidate: selectedRoute,
                                place: place,
                                profile: profile,
                                locationService: locationService
                            )
                        } label: {
                            Label("Start \(selectedRoute.kind.rawValue) route", systemImage: "location.fill")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }

                    Text("Exposure is relative, modelled from traffic volumes, nearby activity, and major crossings. Unknown means no defensible source covers that dimension; Quietside never substitutes missing data with a favorable score.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(16)
        }
        .background(QSColor.cream.opacity(0.38))
        .navigationBarTitleDisplayMode(.inline)
        .task { await calculateRoutes() }
    }

    private var routeMap: some View {
        Map(position: $camera) {
            EnvironmentalMapLayer(store: environment, settings: layers)

            ForEach(drawOrder) { candidate in
                let selected = candidate.id == selectedRoute?.id
                if selected {
                    MapPolyline(candidate.route.polyline)
                        .stroke(.white, style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
                }
                MapPolyline(candidate.route.polyline)
                    .stroke(
                        QSColor.route(candidate.kind).opacity(selected ? 1 : 0.6),
                        style: StrokeStyle(
                            lineWidth: selected ? 7 : 4.5,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: selected ? [] : [1, 7]
                        )
                    )
            }
            Marker("Start", coordinate: origin.coordinate).tint(.secondary)
            Marker(place.name, coordinate: place.coordinate).tint(QSColor.moss)
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .frame(height: 380)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(alignment: .topLeading) {
            Text("TO \(place.name.uppercased())")
                .font(.caption2.bold())
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.thickMaterial, in: Capsule()).padding(12)
        }
        .overlay(alignment: .topTrailing) {
            MapLayerMenu(settings: layers).padding(10)
        }
        .overlay(alignment: .bottomLeading) {
            ExposureLegend(settings: layers).padding(10)
        }
        .task { await environment.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(candidates.count > 1 ? "Choose your route" : "Your walking route").font(.title.bold())
            Text(candidates.count > 1
                 ? "Real Apple Maps walking routes, compared against the exposure shown on the map."
                 : "No nearby walking alternative was meaningfully different. Quietside will not fabricate one.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadRoutes() {
        Task { await calculateRoutes() }
    }

    private func calculateRoutes() async {
        isLoading = true
        errorMessage = nil
        do {
            let start = locationService.latestLocation?.coordinate ?? origin.coordinate
            candidates = try await RouteService().candidates(
                from: start,
                to: place.mapItem,
                profile: profile
            )
            guard !candidates.isEmpty else {
                errorMessage = "Apple Maps did not return a walking route for this destination."
                isLoading = false
                return
            }
            selectedID = candidates.last(where: { $0.kind == .calmest })?.id ?? candidates.first?.id
            var rect = MKMapRect.null
            for candidate in candidates { rect = rect.union(candidate.route.polyline.boundingMapRect) }
            if !rect.isNull {
                let padding = max(rect.size.width, rect.size.height) * 0.18
                camera = .rect(MKMapRect(
                    x: rect.origin.x - padding,
                    y: rect.origin.y - padding,
                    width: rect.size.width + padding * 2,
                    height: rect.size.height + padding * 2
                ))
            }
        } catch {
            errorMessage = "A real route could not be calculated. Check your connection and destination, then try again."
        }
        isLoading = false
    }
}

private struct RouteOptionCard: View {
    let candidate: RouteCandidate
    let profile: SensoryProfile
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Capsule().fill(QSColor.route(candidate.kind)).frame(width: 16, height: 5)
                            Text(candidate.kind.rawValue).font(.title3.bold())
                        }
                        Text("\(candidate.minutes) min · \(candidate.distanceMiles, specifier: "%.2f") mi")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    CalmBadge(score: candidate.sensory.personalizedScore(for: profile))
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(selected ? QSColor.moss : .secondary)
                }
                Text(candidate.explanation).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                if !candidate.highlights.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(candidate.highlights, id: \.self) { highlight in
                            Label(highlight, systemImage: "checkmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(QSColor.mossDark)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let exposure = candidate.exposure, !exposure.profile.isEmpty {
                    ExposureStrip(profile: exposure.profile)
                }
                if selected {
                    Divider()
                    SensoryEvidenceList(sensory: candidate.sensory)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .quietCard()
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(selected ? QSColor.moss : Color.clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
    }
}
