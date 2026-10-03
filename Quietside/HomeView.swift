import SwiftUI
import MapKit

struct HomeView: View {
    let profile: SensoryProfile
    @State private var searchService = PlaceSearchService()
    @State private var query = ""
    @State private var destination: Place?
    @State private var camera: MapCameraPosition = .region(CampusOrigin.region)
    @State private var environment = EnvironmentStore.shared
    @State private var layers = MapLayerSettings.shared
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Map(position: $camera) {
                    EnvironmentalMapLayer(store: environment, settings: layers)
                    Annotation("CIF", coordinate: CampusOrigin.cif.coordinate, anchor: .center) { OriginMarker() }
                }
                .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
                .overlay(alignment: .top) {
                    VStack(alignment: .trailing, spacing: 8) {
                        HStack(alignment: .top) {
                            LayerPicker(settings: layers)
                            Spacer()
                            MapLayerMenu(settings: layers)
                        }
                        HStack(spacing: 8) {
                            EventClockMenu(store: environment)
                            Button {
                                withAnimation { camera = .region(CampusOrigin.region) }
                            } label: { MapControlIcon(systemImage: "location.fill") }
                            .accessibilityLabel("Center on CIF")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                bottomCard
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            .navigationTitle("Quietside")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $destination) { place in
                RouteComparisonView(place: place, profile: profile)
            }
        }
    }

    private var bottomCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(QSColor.routeFast).frame(width: 10, height: 10)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                VStack(alignment: .leading, spacing: 1) {
                    Text("From CIF").font(.subheadline.weight(.semibold))
                    Text("1405 W Springfield Ave").font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search a destination", text: $query)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit(search)
                if searchService.isSearching {
                    ProgressView()
                } else if !query.isEmpty {
                    Button {
                        query = ""
                        searchService.clear()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Clear")
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))

            if let error = searchService.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(QSColor.coral)
            }

            if !searchService.results.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(searchService.results) { place in
                            Button {
                                searchFocused = false
                                destination = place
                            } label: {
                                PlaceRow(place: place)
                            }
                            .buttonStyle(.plain)
                            if place.id != searchService.results.last?.id { Divider() }
                        }
                    }
                }
                .frame(maxHeight: 240)
            } else {
                EventList(store: environment) { event in
                    withAnimation {
                        camera = .region(MKCoordinateRegion(center: event.center, latitudinalMeters: 1_400, longitudinalMeters: 1_400))
                    }
                }
            }
        }
        .quietCard()
    }

    private func search() {
        Task { await searchService.search(query, near: CampusOrigin.location) }
    }
}

private struct PlaceRow: View {
    let place: Place

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill").font(.title3).foregroundStyle(QSColor.moss)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(place.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(DistanceText.string(meters: CampusOrigin.location.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// Today's events and their live state.
private struct EventList: View {
    let store: EnvironmentStore
    let onSelect: (CampusEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today · Homecoming").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            ForEach(CampusEventCatalog.all) { event in
                Button { onSelect(event) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: event.symbol)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(ExposurePalette.event)
                            .frame(width: 26, height: 26)
                            .background(ExposurePalette.event.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text("\(event.timeRange) · \(event.area)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        StatusPill(status: event.status(at: store.now))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(event.status(at: store.now) == .ended ? 0.5 : 1)
            }
        }
    }
}

private struct StatusPill: View {
    let status: CampusEvent.Status

    var body: some View {
        let (text, color): (String, Color) = switch status {
        case .active: ("Live", ExposurePalette.event)
        case .upcoming: ("Upcoming", .secondary)
        case .ended: ("Ended", .secondary)
        }
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(status == .active ? .white : color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(status == .active ? AnyShapeStyle(color) : AnyShapeStyle(Color.primary.opacity(0.07)), in: Capsule())
    }
}
