import Foundation
import CoreLocation

// MARK: - Sensory triggers

/// What the user finds overwhelming. Selected triggers weigh much more in Calmest routing
/// and in the Overall map layer.
nonisolated enum SensoryTrigger: String, Codable, CaseIterable, Identifiable, Sendable {
    case noise, crowds, traffic, lights, visual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .noise: "High noise"
        case .crowds: "Crowds"
        case .traffic: "Traffic"
        case .lights: "Flashing or bright lights"
        case .visual: "Visual stimulation"
        }
    }

    var symbol: String {
        switch self {
        case .noise: "speaker.wave.3.fill"
        case .crowds: "person.3.fill"
        case .traffic: "car.fill"
        case .lights: "light.beacon.max.fill"
        case .visual: "eye.fill"
        }
    }
}

// MARK: - Weighting configuration

/// Central configuration for the environmental model and the Calmest route cost.
/// The map layers and route scoring both read these values.
nonisolated enum EnvironmentalWeights {
    /// AADT range mapped onto 0…1 on a log scale, so arterials do not swamp everything else.
    static let aadtFloor: Double = 300
    static let aadtCeiling: Double = 22_000
    /// >1 suppresses quiet residential streets relative to arterials.
    static let aadtCurve: Double = 2.0

    /// Distance falloff (Gaussian sigma, meters) grows with road intensity.
    static let roadSpreadBase: Double = 16
    static let roadSpreadPerIntensity: Double = 32
    /// Approximate half-width of the carriageway, inside which exposure is at full strength.
    static let roadCoreHalfWidth: Double = 6

    /// Activity locations: Gaussian sigma (meters) and per-category influence.
    static let activitySpread: Double = 35
    static func activityWeight(for category: String) -> Double {
        switch category {
        case "bar", "pub", "nightclub": 0.55
        case "fast_food": 0.30
        case "restaurant": 0.25
        case "cafe", "convenience": 0.15
        case "bakery": 0.12
        case "university": 0.08
        case "library": 0.03
        default: 0.10
        }
    }

    /// Estimated sound level: quiet block → busiest arterial.
    static let ambientNoiseDb: Double = 42
    static let noiseRangeDb: Double = 38
    static func noiseDb(normalized: Double) -> Double { ambientNoiseDb + noiseRangeDb * normalized }

    /// Signalized intersections: Gaussian sigma (meters).
    static let signalSpread: Double = 22

    // Route cost: time × (1 + Σ weight × penalty).
    static let selectedTriggerWeight: Double = 2.0
    static let unselectedTriggerWeight: Double = 0.25
    static let eventWeight: Double = 1.0
    static let eventWeightWhenSensitive: Double = 2.0
    /// Calmest may be at most this much slower than Fastest.
    static let maxDetourFactor: Double = 1.5
    static let maxDetourSeconds: TimeInterval = 8 * 60

    static let highExposureThreshold: Double = 0.5
    static let intersectionCaptureRadius: CLLocationDistance = 30
    static let routeSampleSpacing: CLLocationDistance = 8
}

/// Static pedestrian hubs that set the baseline crowd level around campus.
nonisolated struct CrowdHub: Sendable {
    let name: String
    let coordinate: CLLocationCoordinate2D
    let radius: CLLocationDistance
    let level: Double

    static let campus: [CrowdHub] = [
        CrowdHub(name: "Main Quad", coordinate: .init(latitude: 40.1075, longitude: -88.2272), radius: 130, level: 0.55),
        CrowdHub(name: "Illini Union", coordinate: .init(latitude: 40.1096, longitude: -88.2273), radius: 70, level: 0.6),
        CrowdHub(name: "Green Street", coordinate: .init(latitude: 40.1102, longitude: -88.2310), radius: 150, level: 0.5),
        CrowdHub(name: "Engineering Quad", coordinate: .init(latitude: 40.1110, longitude: -88.2265), radius: 110, level: 0.4),
        CrowdHub(name: "CIF and ECE", coordinate: .init(latitude: 40.1138, longitude: -88.2280), radius: 80, level: 0.35),
        CrowdHub(name: "Six Pack", coordinate: .init(latitude: 40.1040, longitude: -88.2350), radius: 120, level: 0.35),
        CrowdHub(name: "ISR", coordinate: .init(latitude: 40.1104, longitude: -88.2208), radius: 90, level: 0.3),
        CrowdHub(name: "ARC", coordinate: .init(latitude: 40.1012, longitude: -88.2361), radius: 90, level: 0.35),
        CrowdHub(name: "Downtown Champaign", coordinate: .init(latitude: 40.1163, longitude: -88.2435), radius: 160, level: 0.35)
    ]
}

/// Persistent high-stimulation streets: full strength within `halfWidth` of the path,
/// fading over `falloff` meters so the next parallel street stays calm.
nonisolated struct StimulusCorridor: Sendable {
    let name: String
    let path: [CLLocationCoordinate2D]
    let halfWidth: CLLocationDistance
    let falloff: CLLocationDistance
    let crowd: Double
    let noise: Double
    let visual: Double

    static let campus: [StimulusCorridor] = [
        // Campustown's Green Street strip: storefronts, bars, buses, constant foot traffic.
        StimulusCorridor(
            name: "Green Street",
            path: [
                .init(latitude: 40.110334, longitude: -88.228898),  // Wright
                .init(latitude: 40.110310, longitude: -88.230391),  // Sixth
                .init(latitude: 40.110288, longitude: -88.233576),  // Fourth
                .init(latitude: 40.110237, longitude: -88.238716)   // First
            ],
            halfWidth: 22, falloff: 28, crowd: 0.85, noise: 0.6, visual: 0.75
        ),
        // Green Street east of Wright, past the Illini Union.
        StimulusCorridor(
            name: "Green Street",
            path: [
                .init(latitude: 40.110334, longitude: -88.228898),
                .init(latitude: 40.110420, longitude: -88.225800)
            ],
            halfWidth: 18, falloff: 25, crowd: 0.55, noise: 0.35, visual: 0.4
        )
    ]
}

// MARK: - Source records

nonisolated struct RoadwaySegment: Sendable {
    let name: String
    let aadt: Double
    let coordinates: [CLLocationCoordinate2D]

    /// 0…1 relative traffic intensity derived from AADT.
    var intensity: Double {
        let lo = log10(EnvironmentalWeights.aadtFloor)
        let hi = log10(EnvironmentalWeights.aadtCeiling)
        let t = (log10(max(aadt, 1)) - lo) / (hi - lo)
        return pow(min(1, max(0, t)), EnvironmentalWeights.aadtCurve)
    }
}

nonisolated struct ActivityLocation: Sendable {
    let name: String
    let category: String
    let coordinate: CLLocationCoordinate2D

    var weight: Double { EnvironmentalWeights.activityWeight(for: category) }
}

nonisolated struct EnvironmentalStimulus: Identifiable, Sendable {
    nonisolated enum Kind: Sendable { case intersection, visual }
    nonisolated enum Intensity: Sendable { case moderate, high }

    let id: String
    let kind: Kind
    let intensity: Intensity
    let label: String
    let coordinate: CLLocationCoordinate2D
}

// MARK: - Bundled datasets

nonisolated enum EnvironmentalDataLoader {
    static func roadways(bundle: Bundle = .main) -> [RoadwaySegment] {
        guard let url = bundle.url(forResource: "idot_aadt_campustown", withExtension: "geojson"),
              let data = try? Data(contentsOf: url),
              let collection = try? JSONDecoder().decode(RoadwayCollection.self, from: data) else { return [] }
        return collection.features.compactMap { feature in
            guard feature.geometry.type == "LineString", let aadt = feature.properties.AADT, aadt > 0 else { return nil }
            let coordinates = feature.geometry.coordinates.compactMap { position -> CLLocationCoordinate2D? in
                guard position.count >= 2, let lon = position[0], let lat = position[1] else { return nil }
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
            guard coordinates.count >= 2 else { return nil }
            return RoadwaySegment(name: feature.properties.ROAD_NAME ?? "", aadt: aadt, coordinates: coordinates)
        }
    }

    static func activityLocations(bundle: Bundle = .main) -> [ActivityLocation] {
        guard let url = bundle.url(forResource: "campustown_places", withExtension: "geojson"),
              let data = try? Data(contentsOf: url),
              let collection = try? JSONDecoder().decode(PlaceCollection.self, from: data) else { return [] }
        return collection.features.compactMap { feature in
            guard feature.geometry.type == "Point", feature.geometry.coordinates.count >= 2 else { return nil }
            return ActivityLocation(
                name: feature.properties.name ?? "",
                category: feature.properties.category ?? "",
                coordinate: CLLocationCoordinate2D(
                    latitude: feature.geometry.coordinates[1],
                    longitude: feature.geometry.coordinates[0]
                )
            )
        }
    }
}

private nonisolated struct RoadwayCollection: Decodable {
    nonisolated struct Feature: Decodable {
        nonisolated struct Geometry: Decodable {
            let type: String
            let coordinates: [[Double?]]
        }
        nonisolated struct Properties: Decodable {
            let ROAD_NAME: String?
            let AADT: Double?
        }
        let geometry: Geometry
        let properties: Properties
    }
    let features: [Feature]
}

private nonisolated struct PlaceCollection: Decodable {
    nonisolated struct Feature: Decodable {
        nonisolated struct Geometry: Decodable {
            let type: String
            let coordinates: [Double]
        }
        nonisolated struct Properties: Decodable {
            let name: String?
            let category: String?
        }
        let geometry: Geometry
        let properties: Properties
    }
    let features: [Feature]
}

// MARK: - Curated stimuli

/// Static stimulus layer. Intersection coordinates are the crossing points of the
/// corresponding roadway centerlines in the bundled AADT data; visual hotspots are the
/// densest storefront/nightlife clusters in the bundled places data.
nonisolated enum CampustownStimuli {
    static let all: [EnvironmentalStimulus] = intersections + visual

    static let intersections: [EnvironmentalStimulus] = [
        signal("University & Neil", 40.116368, -88.243516, .high),
        signal("University & First", 40.116348, -88.238736, .high),
        signal("University & Fourth", 40.116363, -88.233570, .high),
        signal("University & Wright", 40.116408, -88.228936, .high),
        signal("University & Goodwin", 40.116408, -88.224026, .high),
        signal("University & Lincoln", 40.116438, -88.219386, .high),
        signal("Springfield & Neil", 40.112582, -88.243476, .high),
        signal("Springfield & First", 40.112628, -88.238716, .high),
        signal("Springfield & Fourth", 40.112678, -88.233556, .moderate),
        signal("Springfield & Sixth", 40.112711, -88.230444, .moderate),
        signal("Springfield & Wright", 40.112710, -88.228931, .moderate),
        signal("Springfield & Goodwin", 40.112818, -88.223996, .moderate),
        signal("Springfield & Lincoln", 40.112839, -88.219357, .high),
        signal("Green & Neil", 40.110186, -88.243476, .high),
        signal("Green & First", 40.110237, -88.238716, .moderate),
        signal("Green & Fourth", 40.110288, -88.233576, .moderate),
        signal("Green & Sixth", 40.110310, -88.230391, .moderate),
        signal("Green & Wright", 40.110334, -88.228898, .moderate),
        signal("Green & Lincoln", 40.110578, -88.219326, .high),
        signal("Neil & Stadium", 40.102694, -88.243837, .high),
        signal("Kirby & Neil", 40.098102, -88.244593, .high),
        signal("Kirby & First", 40.098048, -88.238570, .high),
        signal("Kirby & Fourth", 40.098098, -88.233336, .moderate),
        signal("Florida & Lincoln", 40.098183, -88.219088, .high),
        signal("Pennsylvania & Lincoln", 40.100658, -88.219136, .moderate),
        signal("Nevada & Lincoln", 40.105988, -88.219246, .moderate)
    ]

    static let visual: [EnvironmentalStimulus] = [
        hotspot("Green Street storefronts", 40.110242, -88.229953, .high),
        hotspot("Downtown nightlife", 40.116973, -88.242648, .high),
        hotspot("Green & Fifth frontage", 40.110301, -88.232900, .moderate),
        hotspot("Green & Wright frontage", 40.109433, -88.227210, .moderate),
        hotspot("Green & First frontage", 40.110380, -88.237132, .moderate),
        hotspot("Neil Street frontage", 40.111040, -88.243815, .moderate)
    ]

    private static func signal(_ label: String, _ lat: Double, _ lon: Double, _ intensity: EnvironmentalStimulus.Intensity) -> EnvironmentalStimulus {
        EnvironmentalStimulus(
            id: "signal-\(label)", kind: .intersection, intensity: intensity, label: label,
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)
        )
    }

    private static func hotspot(_ label: String, _ lat: Double, _ lon: Double, _ intensity: EnvironmentalStimulus.Intensity) -> EnvironmentalStimulus {
        EnvironmentalStimulus(
            id: "visual-\(label)", kind: .visual, intensity: intensity, label: label,
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)
        )
    }
}
