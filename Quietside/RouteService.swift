import MapKit

enum RouteError: Error {
    case noRoute
}

/// Fastest = least travel time. Calmest = least sensory cost, where
/// cost = Σ time × (1 + weighted noise, crowd, traffic, lights, visual and event penalties),
/// priced on the same environmental snapshot the heatmap draws.
struct RouteService {
    /// Apple walking directions per origin/destination pair. Re-pricing after a trigger or
    /// event change reuses them instead of spending the Directions rate limit.
    private static var directionsCache: [String: [MKRoute]] = [:]

    func walkingRoutes(from origin: CLLocationCoordinate2D, to destination: MKMapItem) async throws -> [MKRoute] {
        let end = destination.placemark.coordinate
        let key = String(format: "%.5f,%.5f>%.5f,%.5f", origin.latitude, origin.longitude, end.latitude, end.longitude)
        if let cached = Self.directionsCache[key] { return cached }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = destination
        request.transportType = .walking
        request.requestsAlternateRoutes = true
        let routes = try await MKDirections(request: request).calculate().routes
        Self.directionsCache[key] = routes
        return routes
    }

    /// Exactly two candidates: Fastest, then Calmest.
    func candidates(
        to destination: MKMapItem,
        from origin: CLLocationCoordinate2D = CampusOrigin.cif.coordinate,
        profile: SensoryProfile
    ) async throws -> [RouteCandidate] {
        let direct = try await walkingRoutes(from: origin, to: destination)
        guard let fastest = direct.min(by: { $0.expectedTravelTime < $1.expectedTravelTime }),
              let snapshot = await EnvironmentStore.shared.currentSnapshot() else { throw RouteError.noRoute }
        let weights = profile.weights

        var routes = [WalkingRoute(fastest)] + direct.filter { $0 !== fastest }.map(WalkingRoute.init)
        routes += await calmerAlternatives(from: origin, to: destination, snapshot: snapshot, weights: weights)

        var priced: [(route: WalkingRoute, exposure: RouteExposure)] = []
        for route in routes {
            guard !priced.contains(where: { Self.isSimilar(route.polyline, $0.route.polyline) }) else { continue }
            let exposure = snapshot.routeExposure(
                along: PolylineGeometry.coordinates(of: route.polyline),
                travelTime: route.expectedTravelTime,
                weights: weights
            )
            priced.append((route, exposure))
        }
        guard let quickest = priced.min(by: { $0.route.expectedTravelTime < $1.route.expectedTravelTime }) else {
            throw RouteError.noRoute
        }

        let fastestTime = quickest.route.expectedTravelTime
        let timeLimit = min(fastestTime * EnvironmentalWeights.maxDetourFactor, fastestTime + EnvironmentalWeights.maxDetourSeconds)
        let calmest = priced
            .filter { $0.route.expectedTravelTime <= timeLimit }
            .min { $0.exposure.cost < $1.exposure.cost } ?? quickest

        return [
            RouteCandidate(kind: .fastest, route: quickest.route, exposure: quickest.exposure),
            RouteCandidate(
                kind: .calmest,
                route: calmest.route,
                exposure: calmest.exposure,
                matchesFastest: calmest.route.polyline === quickest.route.polyline
            )
        ]
    }

    // MARK: Candidate generation

    /// Real Apple walking routes forced through calmer via points.
    private func calmerAlternatives(
        from origin: CLLocationCoordinate2D,
        to destination: MKMapItem,
        snapshot: EnvironmentSnapshot,
        weights: TriggerWeights
    ) async -> [WalkingRoute] {
        let projection = snapshot.projection
        let destinationCoordinate = destination.placemark.coordinate
        let a = projection.point(origin)
        let b = projection.point(destinationCoordinate)
        let length = EnvironmentalExposureModel.length(b - a)
        guard length >= 150 else { return [] }

        func snapped(_ coordinate: CLLocationCoordinate2D, radius: Double) -> CLLocationCoordinate2D {
            snapshot.calmWaypoint(near: coordinate, searchRadius: radius, weights: weights) ?? coordinate
        }
        func usable(_ via: CLLocationCoordinate2D) -> Bool {
            let p = projection.point(via)
            return EnvironmentalExposureModel.length(p - a) > 60 && EnvironmentalExposureModel.length(p - b) > 60
        }

        var viaSets: [[CLLocationCoordinate2D]] = []
        func add(_ vias: [CLLocationCoordinate2D]) {
            guard !vias.isEmpty, vias.allSatisfy(usable) else { return }
            let duplicate = viaSets.contains { existing in
                existing.count == vias.count && zip(existing, vias).allSatisfy {
                    EnvironmentalExposureModel.length(projection.point($0) - projection.point($1)) < 60
                }
            }
            if !duplicate { viaSets.append(vias) }
        }

        // 1. Least-cost corridor over the sensory cost surface.
        if let corridor = snapshot.calmCorridor(from: origin, to: destinationCoordinate, weights: weights), corridor.count > 4 {
            let points = corridor.map(projection.point)
            if let farthest = points.max(by: {
                EnvironmentalExposureModel.distance(from: $0, toSegment: a, b) < EnvironmentalExposureModel.distance(from: $1, toSegment: a, b)
            }), EnvironmentalExposureModel.distance(from: farthest, toSegment: a, b) > 40 {
                add([snapped(projection.coordinate(farthest), radius: 70)])
            }
            add([corridor[corridor.count / 3], corridor[corridor.count * 2 / 3]].map { snapped($0, radius: 70) })
        }

        // 2. Calm side streets either side of the direct line.
        let direction = (b - a) / length
        let normal = SIMD2(-direction.y, direction.x)
        for side in [-1.0, 1.0] {
            let offset = min(400, max(100, length * 0.3)) * side
            let target = projection.coordinate((a + b) / 2 + normal * offset)
            if let via = snapshot.calmWaypoint(near: target, searchRadius: max(120, length * 0.2), weights: weights) {
                add([via])
            }
        }

        let destinationItem = destination
        return await withTaskGroup(of: WalkingRoute?.self) { group in
            for vias in viaSets.prefix(4) {
                group.addTask { @MainActor in
                    let stops = [origin] + vias
                    var legs: [MKRoute] = []
                    for (index, start) in stops.enumerated() {
                        let isLast = index == stops.count - 1
                        let end = isLast ? destinationItem : MKMapItem(placemark: MKPlacemark(coordinate: stops[index + 1]))
                        guard let leg = try? await walkingRoutes(from: start, to: end).first else { return nil }
                        if let previous = legs.last, Self.backtracks(previous.polyline, leg.polyline) { return nil }
                        legs.append(leg)
                    }
                    return WalkingRoute(legs: legs)
                }
            }
            var routes: [WalkingRoute] = []
            for await route in group { if let route { routes.append(route) } }
            return routes
        }
    }

    /// True when a leg starts by retracing the end of the previous leg (a dead-end spur).
    private static func backtracks(_ first: MKPolyline, _ second: MKPolyline) -> Bool {
        let head = PolylineGeometry.coordinates(of: first)
        let tail = PolylineGeometry.coordinates(of: second)
        guard let before = point(head.reversed(), metersAlong: 40),
              let after = point(tail, metersAlong: 40) else { return false }
        return MKMapPoint(before).distance(to: MKMapPoint(after)) < 18
    }

    private static func point(_ coordinates: [CLLocationCoordinate2D], metersAlong target: Double) -> CLLocationCoordinate2D? {
        var travelled = 0.0
        for (a, b) in zip(coordinates, coordinates.dropFirst()) {
            let length = MKMapPoint(a).distance(to: MKMapPoint(b))
            if travelled + length >= target, length > 0 {
                let t = (target - travelled) / length
                return CLLocationCoordinate2D(
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t
                )
            }
            travelled += length
        }
        return nil
    }

    private static func isSimilar(_ lhs: MKPolyline, _ rhs: MKPolyline) -> Bool {
        let coordinates = PolylineGeometry.coordinates(of: lhs)
        guard coordinates.count >= 2 else { return true }
        let probes = stride(from: 0, to: coordinates.count, by: max(1, coordinates.count / 16)).map { coordinates[$0] }
        let mean = probes.reduce(0.0) { total, probe in
            total + (PolylineGeometry.nearestMatch(to: probe, on: rhs)?.distanceToLine ?? 1_000)
        } / Double(probes.count)
        return mean < 20
    }
}

/// Short, factual reasons the Calmest route was chosen, compared with Fastest.
enum RouteComparison {
    static func reasons(calm: RouteExposure, fastest: RouteExposure) -> [String] {
        var reasons: [String] = []
        let quieter = Int((fastest.averageNoiseDb - calm.averageNoiseDb).rounded())
        if quieter >= 2 { reasons.append("\(quieter) dB quieter on average") }
        if fastest.averageCrowd - calm.averageCrowd >= 0.05 { reasons.append("Fewer crowds") }
        if fastest.averageTraffic - calm.averageTraffic >= 0.05 { reasons.append("Avoids busy roads") }
        if calm.intersections.count < fastest.intersections.count {
            reasons.append("\(fastest.intersections.count - calm.intersections.count) fewer signalized crossings")
        }
        if let street = fastest.corridors.first(where: { !calm.corridors.contains($0) }) {
            reasons.insert("Avoids \(street)", at: 0)
        }
        let avoided = fastest.eventIds.filter { !calm.eventIds.contains($0) }
        if let event = CampusEventCatalog.all.first(where: { avoided.contains($0.id) }) {
            reasons.append("Avoids \(event.name)")
        }
        return reasons.isEmpty ? ["Lower overall exposure"] : reasons
    }
}
