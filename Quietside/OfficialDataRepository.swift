import Foundation
import MapKit

struct OfficialDataRepository {
    private let arcGISBase = "https://gisportal.champaignil.gov/ms/rest/services/Open_Data/Open_Data/MapServer"

    static let champaignStreetlights = SourceAttribution(
        id: "champaign-streetlights",
        publisher: "City of Champaign",
        title: "City-owned streetlights",
        url: URL(string: "https://gisportal.champaignil.gov/ms/rest/services/Open_Data/Open_Data/MapServer/34")!,
        retrievedAt: nil,
        coverageNote: "City-owned streetlights only; campus-owned and Urbana lights may be absent."
    )

    static let champaignSignals = SourceAttribution(
        id: "champaign-signals",
        publisher: "City of Champaign",
        title: "Traffic signal intersections",
        url: URL(string: "https://gisportal.champaignil.gov/ms/rest/services/Open_Data/Open_Data/MapServer/35")!,
        retrievedAt: nil,
        coverageNote: "Signal infrastructure is a crossing-complexity proxy, not live traffic volume."
    )

    static let courseExplorer = SourceAttribution(
        id: "uiuc-course-explorer",
        publisher: "University of Illinois Urbana-Champaign",
        title: "Course Explorer API",
        url: URL(string: "https://answers.illinois.edu/88215")!,
        retrievedAt: nil,
        coverageNote: "Schedules can estimate class-change pressure, but are not live occupancy."
    )

    static let nationalNoiseMap = SourceAttribution(
        id: "bts-noise-map",
        publisher: "U.S. Department of Transportation",
        title: "National Transportation Noise Map",
        url: URL(string: "https://www.bts.gov/geospatial/national-transportation-noise-map")!,
        retrievedAt: nil,
        coverageNote: "Broad transportation-noise model; not valid as a live sidewalk measurement."
    )

    static let idotTrafficCounts = SourceAttribution(
        id: "idot-aadt",
        publisher: "Illinois Department of Transportation",
        title: "Annual average daily traffic",
        url: URL(string: "https://www.gettingaroundillinois.com/Traffic%20Counts/index.html")!,
        retrievedAt: nil,
        coverageNote: "Annual traffic volumes on state-counted roads; a relative exposure model, not a decibel reading."
    )

    static let openStreetMapPlaces = SourceAttribution(
        id: "osm-places",
        publisher: "OpenStreetMap contributors",
        title: "Campustown venues",
        url: URL(string: "https://www.openstreetmap.org/copyright")!,
        retrievedAt: nil,
        coverageNote: "Venue locations and types only; not live crowd counts."
    )

    func sensoryEstimate(for route: WalkingRoute, exposure: RouteExposure?) async -> RouteSensory {
        let bounds = expandedBounds(for: route.polyline.boundingMapRect, meters: 80)
        let streetlights = try? await fetchPointLayer(34, inside: bounds)
        let signals = try? await fetchPointLayer(35, inside: bounds)

        let nearbyLights = streetlights?.filter {
            (PolylineGeometry.nearestMatch(to: $0, on: route.polyline)?.distanceToLine ?? .greatestFiniteMagnitude) <= 45
        } ?? []
        let nearbySignals = signals?.filter {
            (PolylineGeometry.nearestMatch(to: $0, on: route.polyline)?.distanceToLine ?? .greatestFiniteMagnitude) <= 35
        } ?? []

        let distanceKM = max(route.distance / 1_000, 0.2)
        let signalDensity = Double(nearbySignals.count) / distanceKM

        let traffic: SignalEstimate
        if signals != nil {
            traffic = SignalEstimate(
                id: "traffic",
                title: "Crossing complexity",
                symbol: "car.fill",
                value: min(1, signalDensity / 5),
                displayValue: "\(nearbySignals.count) signalized crossings nearby",
                detail: "Derived from official traffic-signal locations within 35 m of this route; this is not live vehicle volume.",
                kind: .derivedEstimate,
                confidence: .medium,
                source: Self.champaignSignals
            )
        } else if let exposure {
            traffic = SignalEstimate(
                id: "traffic",
                title: "Crossing complexity",
                symbol: "car.fill",
                value: exposure.intersectionScore(distance: route.distance),
                displayValue: "\(exposure.intersections.count) major signalized crossings",
                detail: "Major signalized intersections on this route, shown as rings on the map.",
                kind: .derivedEstimate,
                confidence: .medium,
                source: Self.champaignSignals
            )
        } else {
            traffic = SignalEstimate(
                id: "traffic",
                title: "Crossing complexity",
                symbol: "car.fill",
                value: nil,
                displayValue: "Unknown",
                detail: "The official signal layer could not be reached.",
                kind: .unavailable,
                confidence: .low,
                source: Self.champaignSignals
            )
        }

        let lighting = SignalEstimate(
            id: "lighting",
            title: "Lighting",
            symbol: "lightbulb.fill",
            value: nil,
            displayValue: streetlights == nil ? "Unknown" : "\(nearbyLights.count) city lights nearby",
            detail: streetlights == nil
                ? "The official streetlight layer could not be reached."
                : "Infrastructure coverage only. Pole locations cannot measure brightness, glare, flicker, or whether a light works.",
            kind: streetlights == nil ? .unavailable : .officialStatic,
            confidence: streetlights == nil ? .low : .medium,
            source: Self.champaignStreetlights
        )

        let noise: SignalEstimate
        let crowds: SignalEstimate
        if let exposure {
            let busyShare = Int((exposure.highExposureShare * 100).rounded())
            noise = SignalEstimate(
                id: "noise",
                title: "Traffic exposure",
                symbol: "speaker.wave.2.fill",
                value: exposure.trafficNoiseScore,
                displayValue: "\(SensoryLevel(score: exposure.trafficNoiseScore).rawValue) · \(busyShare)% beside busy roads",
                detail: "Relative exposure from annual traffic volumes on nearby roads, fading with distance from each road. Not a decibel reading.",
                kind: .derivedEstimate,
                confidence: .medium,
                source: Self.idotTrafficCounts
            )
            let hotspots = exposure.visualStimuli.count
            crowds = SignalEstimate(
                id: "crowds",
                title: "Activity",
                symbol: "person.2.fill",
                value: exposure.activityScore,
                displayValue: hotspots == 0
                    ? SensoryLevel(score: exposure.activityScore).rawValue
                    : "\(hotspots) activity hotspot\(hotspots == 1 ? "" : "s")",
                detail: "Relative activity from nearby bars, restaurants, cafés and shops, weighted by venue type. Not a live crowd count.",
                kind: .derivedEstimate,
                confidence: .medium,
                source: Self.openStreetMapPlaces
            )
        } else {
            noise = SignalEstimate(
                id: "noise",
                title: "Noise",
                symbol: "speaker.wave.2.fill",
                value: nil,
                displayValue: "Outside modelled area",
                detail: "Traffic exposure is modelled for Campustown; this route falls outside that coverage.",
                kind: .unavailable,
                confidence: .low,
                source: Self.nationalNoiseMap
            )
            crowds = SignalEstimate(
                id: "crowds",
                title: "Crowds",
                symbol: "person.2.fill",
                value: nil,
                displayValue: "No live official count",
                detail: "UIUC schedules can support a future class-change estimate, but they do not measure current occupancy.",
                kind: .unavailable,
                confidence: .low,
                source: Self.courseExplorer
            )
        }

        return RouteSensory(noise: noise, crowds: crowds, traffic: traffic, lighting: lighting)
    }

    private func expandedBounds(for rect: MKMapRect, meters: CLLocationDistance) -> MKMapRect {
        let center = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
        let padding = meters * MKMapPointsPerMeterAtLatitude(center.latitude)
        return MKMapRect(
            x: rect.origin.x - padding,
            y: rect.origin.y - padding,
            width: rect.size.width + padding * 2,
            height: rect.size.height + padding * 2
        )
    }

    private func fetchPointLayer(_ layer: Int, inside rect: MKMapRect) async throws -> [CLLocationCoordinate2D] {
        let northwest = MKMapPoint(x: rect.minX, y: rect.minY).coordinate
        let southeast = MKMapPoint(x: rect.maxX, y: rect.maxY).coordinate
        let minLongitude = min(northwest.longitude, southeast.longitude)
        let maxLongitude = max(northwest.longitude, southeast.longitude)
        let minLatitude = min(northwest.latitude, southeast.latitude)
        let maxLatitude = max(northwest.latitude, southeast.latitude)

        var components = URLComponents(string: "\(arcGISBase)/\(layer)/query")!
        components.queryItems = [
            URLQueryItem(name: "where", value: "1=1"),
            URLQueryItem(name: "geometry", value: "\(minLongitude),\(minLatitude),\(maxLongitude),\(maxLatitude)"),
            URLQueryItem(name: "geometryType", value: "esriGeometryEnvelope"),
            URLQueryItem(name: "inSR", value: "4326"),
            URLQueryItem(name: "spatialRel", value: "esriSpatialRelIntersects"),
            URLQueryItem(name: "outFields", value: "OBJECTID"),
            URLQueryItem(name: "outSR", value: "4326"),
            URLQueryItem(name: "returnGeometry", value: "true"),
            URLQueryItem(name: "f", value: "geojson")
        ]
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let collection = try JSONDecoder().decode(GeoJSONFeatureCollection.self, from: data)
        return collection.features.compactMap { feature in
            guard feature.geometry.type == "Point", feature.geometry.coordinates.count >= 2 else { return nil }
            return CLLocationCoordinate2D(
                latitude: feature.geometry.coordinates[1],
                longitude: feature.geometry.coordinates[0]
            )
        }
    }
}

private struct GeoJSONFeatureCollection: Decodable {
    let features: [GeoJSONFeature]
}

private struct GeoJSONFeature: Decodable {
    let geometry: GeoJSONPoint
}

private struct GeoJSONPoint: Decodable {
    let type: String
    let coordinates: [Double]
}
