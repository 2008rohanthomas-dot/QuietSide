import MapKit
import Observation

@MainActor
@Observable
final class PlaceSearchService {
    private(set) var results: [Place] = []
    private(set) var isSearching = false
    private(set) var errorMessage: String?

    func search(_ query: String, near location: CLLocation) async {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = cleaned
        request.resultTypes = [.pointOfInterest, .address]
        request.region = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: 18_000,
            longitudinalMeters: 18_000
        )

        do {
            let response = try await MKLocalSearch(request: request).start()
            results = response.mapItems.prefix(12).map { item in
                let coordinate = item.placemark.coordinate
                let subtitleParts = [item.pointOfInterestCategory?.quietsideLabel, item.placemark.title]
                    .compactMap { $0 }
                return Place(
                    id: "\(coordinate.latitude),\(coordinate.longitude)-\(item.name ?? "place")",
                    name: item.name ?? "Unnamed place",
                    subtitle: subtitleParts.first ?? "Map result",
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )
            }
            if results.isEmpty { errorMessage = "No nearby places matched that search." }
        } catch {
            results = []
            errorMessage = "Search failed. Check your connection and try again."
        }
    }
}

private extension MKPointOfInterestCategory {
    var quietsideLabel: String {
        switch self {
        case .library: "Library"
        case .cafe: "Café"
        case .restaurant: "Restaurant"
        case .park: "Park"
        case .museum: "Museum"
        case .school: "School"
        case .university: "University"
        default: "Place"
        }
    }
}
