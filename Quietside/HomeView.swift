import SwiftUI
import MapKit

struct HomeView: View {
    let profile: SensoryProfile
    let locationService: LocationService
    @State private var searchService = PlaceSearchService()
    @State private var query = ""
    @State private var searchResult: SearchResult?
    @State private var localError: String?
    @State private var manualOrigin: Place?
    @State private var showManualOriginPicker = false
    @State private var camera: MapCameraPosition = .userLocation(followsHeading: false, fallback: .automatic)
    @State private var environment = EnvironmentStore.shared
    @State private var layers = MapLayerSettings.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Map(position: $camera) {
                    EnvironmentalMapLayer(store: environment, settings: layers)
                    UserAnnotation()
                    if let manualOrigin {
                        Marker("Manual start", coordinate: manualOrigin.coordinate).tint(QSColor.amber)
                    }
                }
                .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
                .ignoresSafeArea(edges: .top)

                VStack {
                    HStack(alignment: .top) {
                        ExposureLegend(settings: layers)
                        Spacer()
                        MapLayerMenu(settings: layers)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                VStack(spacing: 14) {
                    locationStatus

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Where do you want to go?").font(.title2.bold())
                        Text("Search real places, then compare real walking routes.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Grainger Library", text: $query)
                                .textInputAutocapitalization(.words)
                                .submitLabel(.search)
                                .onSubmit(search)
                            Button(action: search) {
                                Group {
                                    if searchService.isSearching { ProgressView().tint(.white) }
                                    else { Image(systemName: "arrow.up").font(.headline) }
                                }
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .background(QSColor.moss, in: Circle())
                            }
                            .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searchService.isSearching)
                            .opacity(query.trimmingCharacters(in: .whitespaces).isEmpty ? 0.45 : 1)
                            .accessibilityLabel("Search")
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                PromptChip(text: "Quiet study") { usePrompt("quiet library") }
                                PromptChip(text: "Coffee") { usePrompt("coffee") }
                                PromptChip(text: "Grainger") { usePrompt("Grainger Engineering Library") }
                            }
                        }

                        if let error = localError ?? searchService.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(QSColor.coral)
                        }
                    }
                }
                .quietCard()
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            .navigationTitle("Quietside")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $searchResult) { result in
                RecommendationsView(
                    query: result.query,
                    places: result.places,
                    origin: result.origin,
                    profile: profile,
                    locationService: locationService
                )
            }
            .sheet(isPresented: $showManualOriginPicker) {
                ManualOriginPicker { place in
                    manualOrigin = place
                    localError = nil
                    camera = .region(MKCoordinateRegion(
                        center: place.coordinate,
                        latitudinalMeters: 1_200,
                        longitudinalMeters: 1_200
                    ))
                }
            }
            .task { await environment.load() }
            .onAppear {
                switch locationService.authorizationStatus {
                case .authorizedAlways, .authorizedWhenInUse: locationService.start()
                default: break
                }
            }
        }
    }

    private var locationStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: manualOrigin == nil ? locationService.quality.symbol : "mappin.circle.fill")
                    .foregroundStyle(activeOrigin == nil ? QSColor.amber : QSColor.moss)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ROUTE START").font(.caption2.bold()).foregroundStyle(.secondary)
                    if let manualOrigin {
                        Text("Manual · \(manualOrigin.name)").font(.subheadline.weight(.semibold))
                    } else {
                        Text(locationService.quality.label).font(.subheadline.weight(.semibold))
                    }
                }
                Spacer()
                if activeOrigin != nil {
                    Button {
                        if manualOrigin != nil {
                            manualOrigin = nil
                            locationService.requestPermissionAndStart()
                        }
                        camera = .userLocation(followsHeading: false, fallback: .automatic)
                    } label: {
                        Image(systemName: "location.fill")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(manualOrigin == nil ? "Recenter map" : "Use GPS location")
                }
            }

            if activeOrigin == nil {
                HStack {
                    Button(locationButtonTitle, action: locationAction)
                        .font(.caption.weight(.bold))
                        .buttonStyle(.borderedProminent)
                        .tint(QSColor.moss)
                    Button("Choose start") { showManualOriginPicker = true }
                        .font(.caption.weight(.bold))
                        .buttonStyle(.bordered)
                }
#if targetEnvironment(simulator)
                Text("Simulator: choose Debug → Simulate Location in Xcode, or choose a start manually.")
                    .font(.caption2).foregroundStyle(.secondary)
#endif
            } else if manualOrigin != nil {
                Button("Change manual start") { showManualOriginPicker = true }
                    .font(.caption.weight(.bold))
                    .buttonStyle(.plain)
            }
        }
    }

    private var activeOrigin: CLLocation? {
        if let manualOrigin {
            return CLLocation(latitude: manualOrigin.latitude, longitude: manualOrigin.longitude)
        }
        return locationService.latestLocation
    }

    private var locationButtonTitle: String {
        switch locationService.quality {
        case .denied, .restricted: "Open Settings"
        case .unavailable: "Retry GPS"
        default: "Use location"
        }
    }

    private func locationAction() {
        switch locationService.quality {
        case .denied, .restricted:
            if let settingsURL = URL(string: UIApplication.openSettingsURLString) { openURL(settingsURL) }
        default:
            locationService.requestPermissionAndStart()
        }
    }

    private func usePrompt(_ text: String) {
        query = text
        search()
    }

    private func search() {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        guard let origin = activeOrigin else {
            localError = "Use GPS or choose a starting point before searching."
            locationService.requestPermissionAndStart()
            return
        }
        localError = nil
        Task {
            await searchService.search(cleaned, near: origin)
            guard !searchService.results.isEmpty else { return }
            searchResult = SearchResult(query: cleaned, places: searchService.results, origin: origin)
        }
    }
}

private struct SearchResult: Identifiable {
    let id = UUID()
    let query: String
    let places: [Place]
    let origin: CLLocation
}

private struct PromptChip: View {
    let text: String
    let action: () -> Void
    var body: some View {
        Button(text, action: action)
            .font(.caption.weight(.semibold)).foregroundStyle(QSColor.mossDark)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(QSColor.sage.opacity(0.55), in: Capsule())
    }
}

private struct ManualOriginPicker: View {
    let onSelect: (Place) -> Void
    @State private var query = ""
    @State private var searchService = PlaceSearchService()
    @Environment(\.dismiss) private var dismiss

    private let campusCenter = CLLocation(latitude: 40.1107, longitude: -88.2272)

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Starting address or place", text: $query)
                        .submitLabel(.search)
                        .onSubmit(search)
                    if searchService.isSearching { ProgressView() }
                }
                .padding(12)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)

                if searchService.results.isEmpty {
                    ContentUnavailableView(
                        "Choose a route start",
                        systemImage: "mappin.and.ellipse",
                        description: Text(searchService.errorMessage ?? "Search for your building, address, or a nearby landmark.")
                    )
                } else {
                    List(searchService.results) { place in
                        Button {
                            onSelect(place)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(place.name).font(.headline).foregroundStyle(.primary)
                                Text(place.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Choose starting point")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
        }
    }

    private func search() {
        Task { await searchService.search(query, near: campusCenter) }
    }
}
