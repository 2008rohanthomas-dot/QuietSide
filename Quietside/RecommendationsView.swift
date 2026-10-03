import SwiftUI
import CoreLocation

struct RecommendationsView: View {
    let query: String
    let places: [Place]
    let origin: CLLocation
    let profile: SensoryProfile
    let locationService: LocationService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Places from Apple Maps").font(.largeTitle.bold())
                        Text("“\(query)”").font(.subheadline).foregroundStyle(.secondary)
                    }

                    ForEach(places) { place in
                        NavigationLink(value: place) {
                            PlaceCard(place: place, origin: origin)
                        }
                        .buttonStyle(.plain)
                    }

                    Label(
                        "Quietside evaluates official evidence only after it has a real route. Search results are not assigned invented calmness scores.",
                        systemImage: "checkmark.shield"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                }
                .padding(20)
            }
            .background(QSColor.cream.opacity(0.45))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
            }
            .navigationDestination(for: Place.self) { place in
                RouteComparisonView(
                    place: place,
                    origin: origin,
                    profile: profile,
                    locationService: locationService
                )
            }
        }
    }
}

private struct PlaceCard: View {
    let place: Place
    let origin: CLLocation

    private var distance: CLLocationDistance {
        origin.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(place.name).font(.title3.bold())
                    Text(place.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(QSColor.moss)
            }
            Label("\(DistanceText.string(meters: distance)) away", systemImage: "location")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("Select to calculate walking alternatives and inspect the evidence available for each route.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .quietCard()
    }
}
