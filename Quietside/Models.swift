import Foundation
import MapKit

/// The user's sensory triggers. Selected triggers weigh more in Calmest routing.
struct SensoryProfile: Codable, Equatable {
    var triggers: Set<SensoryTrigger> = [.noise, .crowds]

    var weights: TriggerWeights { TriggerWeights(triggers: triggers) }

    private static let storageKey = "sensoryTriggers"

    static func load() -> SensoryProfile {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let profile = try? JSONDecoder().decode(SensoryProfile.self, from: data) else {
            return SensoryProfile()
        }
        return profile
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

enum ExposureLevel: String {
    case low = "Low"
    case moderate = "Moderate"
    case high = "High"

    init(_ value: Double) {
        if value < 0.33 { self = .low }
        else if value < 0.6 { self = .moderate }
        else { self = .high }
    }
}

struct Place: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var mapItem: MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        return item
    }
}

/// The demo's fixed starting point: the Campus Instructional Facility.
enum CampusOrigin {
    static let cif = Place(
        id: "cif",
        name: "CIF",
        subtitle: "Campus Instructional Facility · 1405 W Springfield Ave",
        latitude: 40.11246,
        longitude: -88.22832
    )

    static var location: CLLocation { CLLocation(latitude: cif.latitude, longitude: cif.longitude) }

    static let region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.1095, longitude: -88.2290),
        latitudinalMeters: 1_500,
        longitudinalMeters: 1_500
    )
}

enum RouteKind: String {
    case fastest = "Fastest"
    case calmest = "Calmest"
}

/// Real Apple Maps walking geometry: a single `MKRoute` or consecutive legs through
/// calm via points. Immutable, so safe to share across tasks.
struct WalkingRoute: @unchecked Sendable {
    struct Step {
        let instructions: String
        let distance: CLLocationDistance
    }

    let polyline: MKPolyline
    let distance: CLLocationDistance
    let expectedTravelTime: TimeInterval
    let steps: [Step]

    init(_ route: MKRoute) {
        self.init(legs: [route])
    }

    init(legs: [MKRoute]) {
        var coordinates: [CLLocationCoordinate2D] = []
        var merged: [Step] = []
        for (index, leg) in legs.enumerated() {
            let points = PolylineGeometry.coordinates(of: leg.polyline)
            coordinates += index == 0 ? points : Array(points.dropFirst())
            var steps = leg.steps.enumerated()
                .filter { offset, step in index == 0 || offset > 0 || step.distance > 1 }
                .map { Step(instructions: $0.element.instructions, distance: $0.element.distance) }
            // A leg that ends at a via point continues rather than "arrives".
            if index < legs.count - 1, let arrival = steps.popLast() {
                steps.append(Step(instructions: "Continue straight", distance: arrival.distance))
            }
            merged += steps
        }
        polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        distance = legs.reduce(0) { $0 + $1.distance }
        expectedTravelTime = legs.reduce(0) { $0 + $1.expectedTravelTime }
        steps = merged
    }
}

struct RouteCandidate: Identifiable {
    let id = UUID()
    let kind: RouteKind
    let route: WalkingRoute
    let exposure: RouteExposure
    /// True when the lowest-cost route is the fastest route itself.
    var matchesFastest = false

    var minutes: Int { max(1, Int(ceil(route.expectedTravelTime / 60))) }
    var distanceMiles: Double { route.distance / 1_609.344 }
}

struct NavigationProgress {
    let snappedCoordinate: CLLocationCoordinate2D
    let fractionComplete: Double
    let remainingDistance: CLLocationDistance
    let remainingTime: TimeInterval
    let currentStepIndex: Int
    let distanceToManeuver: CLLocationDistance
}

enum DistanceText {
    static func string(meters: CLLocationDistance) -> String {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .naturalScale
        formatter.numberFormatter.maximumFractionDigits = meters < 160 ? 0 : 1
        return formatter.string(from: Measurement(value: meters, unit: UnitLength.meters))
    }
}
