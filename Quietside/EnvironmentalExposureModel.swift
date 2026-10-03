import Foundation
import CoreLocation

/// Equirectangular projection around Campustown. Accurate to well under a meter at this scale.
nonisolated struct LocalProjection: Sendable {
    let origin: CLLocationCoordinate2D
    let metersPerDegreeLongitude: Double
    let metersPerDegreeLatitude: Double = 110_574

    init(origin: CLLocationCoordinate2D) {
        self.origin = origin
        metersPerDegreeLongitude = 111_320 * cos(origin.latitude * .pi / 180)
    }

    func point(_ coordinate: CLLocationCoordinate2D) -> SIMD2<Double> {
        SIMD2(
            (coordinate.longitude - origin.longitude) * metersPerDegreeLongitude,
            (coordinate.latitude - origin.latitude) * metersPerDegreeLatitude
        )
    }

    func coordinate(_ point: SIMD2<Double>) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: origin.latitude + point.y / metersPerDegreeLatitude,
            longitude: origin.longitude + point.x / metersPerDegreeLongitude
        )
    }
}

/// Regular raster of values in projected meters.
nonisolated struct ExposureGrid: Sendable {
    let originX: Double
    let originY: Double
    let cellSize: Double
    let columns: Int
    let rows: Int
    var values: [Float]

    subscript(column: Int, row: Int) -> Double {
        Double(values[row * columns + column])
    }

    func center(column: Int, row: Int) -> SIMD2<Double> {
        SIMD2(originX + Double(column) * cellSize, originY + Double(row) * cellSize)
    }

    func cell(containing point: SIMD2<Double>) -> (column: Int, row: Int)? {
        let column = Int(((point.x - originX) / cellSize).rounded())
        let row = Int(((point.y - originY) / cellSize).rounded())
        guard column > 0, row > 0, column < columns - 1, row < rows - 1 else { return nil }
        return (column, row)
    }

    /// Bilinear sample; zero outside the modelled area.
    func value(at point: SIMD2<Double>) -> Double {
        let fx = (point.x - originX) / cellSize
        let fy = (point.y - originY) / cellSize
        guard fx >= 0, fy >= 0, fx < Double(columns - 1), fy < Double(rows - 1) else { return 0 }
        let i = Int(fx), j = Int(fy)
        let tx = fx - Double(i), ty = fy - Double(j)
        let bottom = self[i, j] * (1 - tx) + self[i + 1, j] * tx
        let top = self[i, j + 1] * (1 - tx) + self[i + 1, j + 1] * tx
        return bottom * (1 - ty) + top * ty
    }

    func mapped(_ transform: (Int) -> Float) -> ExposureGrid {
        var copy = self
        for index in values.indices { copy.values[index] = transform(index) }
        return copy
    }
}

// MARK: - Samples, layers, weights

/// Environmental conditions at one point, as used by both the map and routing.
nonisolated struct EnvironmentalSample: Sendable {
    let noiseDb: Double
    let crowdLevel: Double
    let trafficLevel: Double
    let visualStimulus: Double
    let trafficSignalExposure: Double
    let eventInfluence: Double
    let activeEventIds: [String]
}

nonisolated enum EnvironmentalLayer: String, CaseIterable, Identifiable, Sendable {
    case overall, noise, crowd, traffic

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overall: "Overall"
        case .noise: "Noise"
        case .crowd: "Crowd"
        case .traffic: "Traffic"
        }
    }
    var lowLabel: String {
        switch self {
        case .overall: "Calm"
        case .noise: "\(Int(EnvironmentalWeights.noiseDb(normalized: EnvironmentalExposureModel.bandThresholds[0]))) dB"
        case .crowd: "Quiet"
        case .traffic: "Light"
        }
    }
    var highLabel: String {
        switch self {
        case .overall: "Intense"
        case .noise: "\(Int(EnvironmentalWeights.noiseDb(normalized: EnvironmentalExposureModel.bandThresholds[4])))+ dB"
        case .crowd: "Packed"
        case .traffic: "Heavy"
        }
    }
}

/// Per-dimension cost weights derived from the user's triggers.
nonisolated struct TriggerWeights: Sendable, Equatable {
    let noise: Double
    let crowds: Double
    let traffic: Double
    let lights: Double
    let visual: Double
    let events: Double

    init(triggers: Set<SensoryTrigger>) {
        func weight(_ trigger: SensoryTrigger) -> Double {
            triggers.contains(trigger) ? EnvironmentalWeights.selectedTriggerWeight : EnvironmentalWeights.unselectedTriggerWeight
        }
        noise = weight(.noise)
        crowds = weight(.crowds)
        traffic = weight(.traffic)
        lights = weight(.lights)
        visual = weight(.visual)
        events = triggers.contains(.crowds) || triggers.contains(.noise)
            ? EnvironmentalWeights.eventWeightWhenSensitive
            : EnvironmentalWeights.eventWeight
    }

    private var total: Double { noise + crowds + traffic + lights + visual }

    /// Extra cost per second walked at a point (0 = no stimulation).
    func penalty(noiseNormalized: Double, crowd: Double, traffic trafficLevel: Double,
                 visual visualLevel: Double, signal: Double, event: Double) -> Double {
        let noisePart = max(0, (noiseNormalized - 0.2) / 0.8)
        let lightsPart = min(1, 0.75 * signal + 0.35 * visualLevel)
        return noise * noisePart + crowds * crowd + traffic * trafficLevel
            + lights * lightsPart + visual * visualLevel + events * event
    }

    /// 0…1 "Overall" exposure for the map, from the same penalty used in routing.
    func overall(penalty: Double) -> Double {
        1 - exp(-2.2 * penalty / total)
    }
}

/// Environmental exposure and Calmest cost along one route.
nonisolated struct RouteExposure: Sendable {
    let averageNoiseDb: Double
    let peakNoiseDb: Double
    let averageCrowd: Double
    let averageTraffic: Double
    let averageVisual: Double
    let highExposureShare: Double
    let intersections: [EnvironmentalStimulus]
    let eventIds: [String]
    /// Seeded high-stimulation corridors the route walks along (e.g. "Green Street").
    let corridors: [String]
    /// Overall exposure resampled at even intervals from start to destination.
    let profile: [Double]
    /// Consecutive ~30 m pieces of the route with their environmental values, for drawing.
    let segments: [RouteExposureSegment]
    /// Travel time plus weighted sensory penalties, in seconds.
    let cost: Double
}

/// One stretch of a route, valued on the same grids as the heatmap.
nonisolated struct RouteExposureSegment: Sendable {
    let coordinates: [CLLocationCoordinate2D]
    /// Normalized 0…1 values.
    let noise: Double
    let crowd: Double
    let traffic: Double
    let overall: Double

    func value(for layer: EnvironmentalLayer) -> Double {
        switch layer {
        case .overall: overall
        case .noise: noise
        case .crowd: crowd
        case .traffic: traffic
        }
    }
}

nonisolated struct ExposureContourBand: Sendable {
    nonisolated struct Polygon: Sendable {
        let exterior: [CLLocationCoordinate2D]
        let holes: [[CLLocationCoordinate2D]]
    }
    let level: Int
    let threshold: Double
    let polygons: [Polygon]
}

// MARK: - Base field

/// Static environmental field for Campustown built from the bundled datasets:
/// IDOT AADT roadways → traffic; venues + pedestrian hubs → crowd; hotspots → visual;
/// signalized intersections → signal exposure. Events are layered on per `snapshot(at:)`.
nonisolated final class EnvironmentalExposureModel: Sendable {
    static let bandThresholds: [Double] = [0.2, 0.35, 0.5, 0.66, 0.82]

    let projection: LocalProjection
    let traffic: ExposureGrid
    let crowd: ExposureGrid
    let visual: ExposureGrid
    let signal: ExposureGrid
    /// Persistent street-activity noise from seeded corridors, 0…1.
    let streetNoise: ExposureGrid
    let corridors: [StimulusCorridor]
    let stimuli: [EnvironmentalStimulus]
    let streetAnchors: [SIMD2<Double>]

    static func loadBundled() -> EnvironmentalExposureModel? {
        let roadways = EnvironmentalDataLoader.roadways()
        guard !roadways.isEmpty else { return nil }
        return EnvironmentalExposureModel(
            roadways: roadways,
            activityLocations: EnvironmentalDataLoader.activityLocations(),
            stimuli: CampustownStimuli.all,
            hubs: CrowdHub.campus,
            corridors: StimulusCorridor.campus
        )
    }

    init(
        roadways: [RoadwaySegment],
        activityLocations: [ActivityLocation],
        stimuli: [EnvironmentalStimulus],
        hubs: [CrowdHub],
        corridors: [StimulusCorridor] = [],
        cellSize: Double = 12,
        margin: Double = 250
    ) {
        let allCoordinates = roadways.flatMap(\.coordinates)
        let minLat = allCoordinates.map(\.latitude).min() ?? 40.108
        let maxLat = allCoordinates.map(\.latitude).max() ?? 40.108
        let minLon = allCoordinates.map(\.longitude).min() ?? -88.227
        let maxLon = allCoordinates.map(\.longitude).max() ?? -88.227
        let projection = LocalProjection(origin: CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        ))
        let low = projection.point(CLLocationCoordinate2D(latitude: minLat, longitude: minLon))
        let high = projection.point(CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon))
        let originX = low.x - margin, originY = low.y - margin
        let columns = Int(((high.x + margin) - originX) / cellSize) + 2
        let rows = Int(((high.y + margin) - originY) / cellSize) + 2
        let empty = ExposureGrid(originX: originX, originY: originY, cellSize: cellSize,
                                 columns: columns, rows: rows, values: Array(repeating: 0, count: columns * rows))

        /// Visits every cell within `reach` of a point, passing the cell index and distance.
        func splat(_ p: SIMD2<Double>, reach: Double, _ body: (Int, Double) -> Void) {
            let c0 = max(0, Int((p.x - reach - originX) / cellSize))
            let c1 = min(columns - 1, Int((p.x + reach - originX) / cellSize) + 1)
            let r0 = max(0, Int((p.y - reach - originY) / cellSize))
            let r1 = min(rows - 1, Int((p.y + reach - originY) / cellSize) + 1)
            guard c0 <= c1, r0 <= r1 else { return }
            for row in r0...r1 {
                for column in c0...c1 {
                    let d = Self.length(empty.center(column: column, row: row) - p)
                    if d <= reach { body(row * columns + column, d) }
                }
            }
        }

        // Traffic: max of distance-decayed AADT intensity over all segments.
        var traffic = empty
        let core = EnvironmentalWeights.roadCoreHalfWidth
        for segment in roadways {
            let intensity = segment.intensity
            guard intensity > 0.01 else { continue }
            let sigma = EnvironmentalWeights.roadSpreadBase + EnvironmentalWeights.roadSpreadPerIntensity * intensity
            let reach = core + sigma * 3.5
            let points = segment.coordinates.map(projection.point)
            for (a, b) in zip(points, points.dropFirst()) {
                let c0 = max(0, Int((min(a.x, b.x) - reach - originX) / cellSize))
                let c1 = min(columns - 1, Int((max(a.x, b.x) + reach - originX) / cellSize) + 1)
                let r0 = max(0, Int((min(a.y, b.y) - reach - originY) / cellSize))
                let r1 = min(rows - 1, Int((max(a.y, b.y) + reach - originY) / cellSize) + 1)
                guard c0 <= c1, r0 <= r1 else { continue }
                for row in r0...r1 {
                    for column in c0...c1 {
                        let d = Self.distance(from: empty.center(column: column, row: row), toSegment: a, b)
                        guard d <= reach else { continue }
                        let falloff = max(0, d - core) / sigma
                        let value = Float(intensity * exp(-0.5 * falloff * falloff))
                        let index = row * columns + column
                        if value > traffic.values[index] { traffic.values[index] = value }
                    }
                }
            }
        }

        // Venue activity: probabilistic union of category-weighted Gaussians.
        var logQuietActivity = [Double](repeating: 0, count: columns * rows)
        let activitySigma = EnvironmentalWeights.activitySpread
        for location in activityLocations {
            let weight = min(0.95, location.weight)
            guard weight > 0 else { continue }
            splat(projection.point(location.coordinate), reach: activitySigma * 3.5) { index, d in
                logQuietActivity[index] += log(1 - weight * exp(-0.5 * d * d / (activitySigma * activitySigma)))
            }
        }

        // Pedestrian hubs.
        var logQuietHubs = [Double](repeating: 0, count: columns * rows)
        for hub in hubs {
            let sigma = hub.radius * 0.7
            splat(projection.point(hub.coordinate), reach: sigma * 3.5) { index, d in
                logQuietHubs[index] += log(1 - min(0.95, hub.level) * exp(-0.5 * d * d / (sigma * sigma)))
            }
        }

        // Visual hotspots and signalized intersections.
        var hotspotQuiet = [Double](repeating: 1, count: columns * rows)
        var signal = empty
        for stimulus in stimuli {
            let p = projection.point(stimulus.coordinate)
            switch stimulus.kind {
            case .visual:
                let level = stimulus.intensity == .high ? 0.8 : 0.55
                let sigma = 45.0
                splat(p, reach: sigma * 3.5) { index, d in
                    hotspotQuiet[index] *= 1 - level * exp(-0.5 * d * d / (sigma * sigma))
                }
            case .intersection:
                let level = stimulus.intensity == .high ? 0.9 : 0.6
                let sigma = EnvironmentalWeights.signalSpread
                splat(p, reach: sigma * 3.5) { index, d in
                    let value = Float(level * exp(-0.5 * d * d / (sigma * sigma)))
                    if value > signal.values[index] { signal.values[index] = value }
                }
            }
        }

        // Seeded high-stimulation corridors.
        var corridorCrowd = empty, corridorNoise = empty, corridorVisual = empty
        for corridor in corridors {
            let reach = corridor.halfWidth + corridor.falloff * 3.5
            let points = corridor.path.map(projection.point)
            for (a, b) in zip(points, points.dropFirst()) {
                let c0 = max(0, Int((min(a.x, b.x) - reach - originX) / cellSize))
                let c1 = min(columns - 1, Int((max(a.x, b.x) + reach - originX) / cellSize) + 1)
                let r0 = max(0, Int((min(a.y, b.y) - reach - originY) / cellSize))
                let r1 = min(rows - 1, Int((max(a.y, b.y) + reach - originY) / cellSize) + 1)
                guard c0 <= c1, r0 <= r1 else { continue }
                for row in r0...r1 {
                    for column in c0...c1 {
                        let d = Self.distance(from: empty.center(column: column, row: row), toSegment: a, b)
                        guard d <= reach else { continue }
                        let beyond = max(0, d - corridor.halfWidth) / corridor.falloff
                        let influence = exp(-0.5 * beyond * beyond)
                        let index = row * columns + column
                        corridorCrowd.values[index] = max(corridorCrowd.values[index], Float(corridor.crowd * influence))
                        corridorNoise.values[index] = max(corridorNoise.values[index], Float(corridor.noise * influence))
                        corridorVisual.values[index] = max(corridorVisual.values[index], Float(corridor.visual * influence))
                    }
                }
            }
        }

        let crowd = empty.mapped { index -> Float in
            let activity: Double = 1 - exp(logQuietActivity[index])
            let quiet: Double = (1 - 0.75 * activity) * exp(logQuietHubs[index]) * (1 - Double(corridorCrowd.values[index]))
            return Float(1 - quiet)
        }
        let visual = empty.mapped { index -> Float in
            let activity: Double = 1 - exp(logQuietActivity[index])
            let road: Double = 1 - 0.15 * Double(traffic.values[index])
            let quiet: Double = hotspotQuiet[index] * (1 - 0.45 * activity) * road * (1 - Double(corridorVisual.values[index]))
            return Float(1 - quiet)
        }

        // Minor-street points used as via points for calmer route candidates.
        var anchors: [SIMD2<Double>] = []
        for segment in roadways where segment.intensity < 0.45 {
            let points = segment.coordinates.map(projection.point)
            for (a, b) in zip(points, points.dropFirst()) {
                let steps = max(1, Int(Self.length(b - a) / 25))
                for step in 0...steps { anchors.append(a + (b - a) * (Double(step) / Double(steps))) }
            }
        }

        self.projection = projection
        self.traffic = traffic
        self.crowd = crowd
        self.visual = visual
        self.signal = signal
        self.streetNoise = corridorNoise
        self.corridors = corridors
        self.stimuli = stimuli
        self.streetAnchors = anchors
    }

    /// The field at a moment in time, with active events applied.
    func snapshot(at date: Date, events: [CampusEvent] = CampusEventCatalog.all) -> EnvironmentSnapshot {
        EnvironmentSnapshot(base: self, date: date, activeEvents: events.filter { $0.status(at: date) == .active })
    }

    // MARK: Geometry

    static func length(_ v: SIMD2<Double>) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }

    static func distance(from p: SIMD2<Double>, toSegment a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let ab = b - a
        let denominator = ab.x * ab.x + ab.y * ab.y
        let t = denominator > 0 ? min(1, max(0, ((p - a).x * ab.x + (p - a).y * ab.y) / denominator)) : 0
        return length(p - (a + ab * t))
    }
}

// MARK: - Snapshot

/// Environmental channels at one moment. Every map layer and every route cost reads these grids.
nonisolated final class EnvironmentSnapshot: Sendable {
    let base: EnvironmentalExposureModel
    let date: Date
    let activeEvents: [CampusEvent]
    /// Noise, normalized 0…1 (see `EnvironmentalWeights.noiseDb(normalized:)`).
    let noise: ExposureGrid
    let crowd: ExposureGrid
    let traffic: ExposureGrid
    let visual: ExposureGrid
    let signal: ExposureGrid
    /// Strongest active-event influence, 0…1.
    let event: ExposureGrid

    var projection: LocalProjection { base.projection }

    init(base: EnvironmentalExposureModel, date: Date, activeEvents: [CampusEvent]) {
        self.base = base
        self.date = date
        self.activeEvents = activeEvents

        var crowd = base.crowd, traffic = base.traffic, visual = base.visual
        var event = base.crowd.mapped { _ in 0 }
        var eventNoise = [Float](repeating: 0, count: crowd.values.count)
        for active in activeEvents {
            let center = base.projection.point(active.center)
            let reach = active.reach
            let grid = base.crowd
            let c0 = max(0, Int((center.x - reach - grid.originX) / grid.cellSize))
            let c1 = min(grid.columns - 1, Int((center.x + reach - grid.originX) / grid.cellSize) + 1)
            let r0 = max(0, Int((center.y - reach - grid.originY) / grid.cellSize))
            let r1 = min(grid.rows - 1, Int((center.y + reach - grid.originY) / grid.cellSize) + 1)
            guard c0 <= c1, r0 <= r1 else { continue }
            for row in r0...r1 {
                for column in c0...c1 {
                    let d = EnvironmentalExposureModel.length(grid.center(column: column, row: row) - center)
                    let influence = active.influence(atDistance: d)
                    guard influence > 0.01 else { continue }
                    let index = row * grid.columns + column
                    func raise(_ value: Float, by amount: Double) -> Float {
                        Float(1 - (1 - Double(value)) * (1 - amount * influence))
                    }
                    crowd.values[index] = raise(crowd.values[index], by: active.effects.crowd)
                    traffic.values[index] = raise(traffic.values[index], by: active.effects.traffic)
                    visual.values[index] = raise(visual.values[index], by: active.effects.visual)
                    eventNoise[index] = raise(eventNoise[index], by: active.effects.noise)
                    event.values[index] = max(event.values[index], Float(influence))
                }
            }
        }

        let finalCrowd = crowd, finalTraffic = traffic
        self.noise = base.crowd.mapped { index -> Float in
            let road: Double = 1 - 0.85 * Double(finalTraffic.values[index])
            let people: Double = 1 - 0.35 * Double(finalCrowd.values[index])
            let events: Double = 1 - Double(eventNoise[index])
            let street: Double = 1 - Double(base.streetNoise.values[index])
            return Float(1 - road * people * events * street)
        }
        self.crowd = crowd
        self.traffic = traffic
        self.visual = visual
        self.signal = base.signal
        self.event = event
    }

    // MARK: Point queries

    func sample(at coordinate: CLLocationCoordinate2D) -> EnvironmentalSample {
        let p = projection.point(coordinate)
        return EnvironmentalSample(
            noiseDb: EnvironmentalWeights.noiseDb(normalized: noise.value(at: p)),
            crowdLevel: crowd.value(at: p),
            trafficLevel: traffic.value(at: p),
            visualStimulus: visual.value(at: p),
            trafficSignalExposure: signal.value(at: p),
            eventInfluence: event.value(at: p),
            activeEventIds: activeEvents
                .filter { $0.influence(atDistance: EnvironmentalExposureModel.length(projection.point($0.center) - p)) > 0.3 }
                .map(\.id)
        )
    }

    private func penalty(at p: SIMD2<Double>, _ weights: TriggerWeights) -> Double {
        weights.penalty(
            noiseNormalized: noise.value(at: p), crowd: crowd.value(at: p), traffic: traffic.value(at: p),
            visual: visual.value(at: p), signal: signal.value(at: p), event: event.value(at: p)
        )
    }

    private func penalty(cell index: Int, _ weights: TriggerWeights) -> Double {
        weights.penalty(
            noiseNormalized: Double(noise.values[index]), crowd: Double(crowd.values[index]),
            traffic: Double(traffic.values[index]), visual: Double(visual.values[index]),
            signal: Double(signal.values[index]), event: Double(event.values[index])
        )
    }

    // MARK: Map layers

    func layerGrid(_ layer: EnvironmentalLayer, weights: TriggerWeights) -> ExposureGrid {
        let source: ExposureGrid
        switch layer {
        case .noise: source = noise
        case .crowd: source = crowd
        case .traffic: source = traffic
        case .overall: source = noise.mapped { Float(weights.overall(penalty: penalty(cell: $0, weights))) }
        }
        // Zero border so every contour closes.
        return source.mapped { index in
            let column = index % source.columns, row = index / source.columns
            let border = row == 0 || column == 0 || row == source.rows - 1 || column == source.columns - 1
            return border ? 0 : source.values[index]
        }
    }

    func contours(for layer: EnvironmentalLayer, weights: TriggerWeights) -> [ExposureContourBand] {
        let grid = layerGrid(layer, weights: weights)
        return EnvironmentalExposureModel.bandThresholds.enumerated().map { level, threshold in
            ExposureContourBand(
                level: level,
                threshold: threshold,
                polygons: ContourTracer.polygons(in: grid, threshold: threshold, projection: projection)
            )
        }
    }

    // MARK: Routes

    /// Samples a route every few meters and prices it: Σ time × (1 + penalty).
    func routeExposure(along coordinates: [CLLocationCoordinate2D], travelTime: TimeInterval, weights: TriggerWeights) -> RouteExposure {
        let points = coordinates.map(projection.point)
        let totalLength = zip(points, points.dropFirst()).reduce(0) { $0 + EnvironmentalExposureModel.length($1.1 - $1.0) }
        guard points.count >= 2, totalLength > 0 else {
            return RouteExposure(averageNoiseDb: EnvironmentalWeights.ambientNoiseDb, peakNoiseDb: EnvironmentalWeights.ambientNoiseDb,
                                 averageCrowd: 0, averageTraffic: 0, averageVisual: 0, highExposureShare: 0,
                                 intersections: [], eventIds: [], corridors: [], profile: [], segments: [], cost: travelTime)
        }

        let spacing = EnvironmentalWeights.routeSampleSpacing
        let secondsPerMeter = travelTime / totalLength
        var noiseSum = 0.0, peakNoise = 0.0, crowdSum = 0.0, trafficSum = 0.0, visualSum = 0.0
        var high = 0, count = 0, cost = 0.0
        var overallValues: [Double] = []
        var eventIds = Set<String>()
        var segments: [RouteExposureSegment] = []
        var chunk: [SIMD2<Double>] = [points[0]]
        var chunkSums = SIMD4<Double>(repeating: 0)
        var chunkCount = 0
        func closeChunk() {
            guard chunkCount > 0, chunk.count >= 2 else { return }
            let mean = chunkSums / Double(chunkCount)
            segments.append(RouteExposureSegment(
                coordinates: chunk.map(projection.coordinate),
                noise: mean[0], crowd: mean[1], traffic: mean[2], overall: mean[3]
            ))
            chunk = [chunk[chunk.count - 1]]
            chunkSums = SIMD4(repeating: 0)
            chunkCount = 0
        }

        for (a, b) in zip(points, points.dropFirst()) {
            let length = EnvironmentalExposureModel.length(b - a)
            guard length > 0 else { continue }
            let steps = max(1, Int((length / spacing).rounded(.up)))
            let stepLength = length / Double(steps)
            for step in 0..<steps {
                let p = a + (b - a) * ((Double(step) + 0.5) / Double(steps))
                let n = noise.value(at: p)
                let c = crowd.value(at: p)
                let t = traffic.value(at: p)
                let penalty = penalty(at: p, weights)
                let overall = weights.overall(penalty: penalty)
                noiseSum += n
                peakNoise = max(peakNoise, n)
                crowdSum += c
                trafficSum += t
                visualSum += visual.value(at: p)
                chunk.append(a + (b - a) * (Double(step + 1) / Double(steps)))
                chunkSums += SIMD4(n, c, t, overall)
                chunkCount += 1
                if chunkCount >= 4 { closeChunk() }
                if overall >= EnvironmentalWeights.highExposureThreshold { high += 1 }
                overallValues.append(overall)
                cost += stepLength * secondsPerMeter * (1 + penalty)
                count += 1
                if event.value(at: p) > 0.3 {
                    for active in activeEvents where active.influence(
                        atDistance: EnvironmentalExposureModel.length(projection.point(active.center) - p)) > 0.3 {
                        eventIds.insert(active.id)
                    }
                }
            }
        }
        closeChunk()
        let n = Double(max(count, 1))

        let binCount = 40
        let profile = (0..<binCount).map { bin -> Double in
            let lo = bin * overallValues.count / binCount
            let hi = min(overallValues.count, max(lo + 1, (bin + 1) * overallValues.count / binCount))
            let slice = overallValues[min(lo, overallValues.count)..<hi]
            return slice.isEmpty ? 0 : slice.reduce(0, +) / Double(slice.count)
        }

        let intersections = base.stimuli.filter { stimulus in
            guard stimulus.kind == .intersection else { return false }
            let p = projection.point(stimulus.coordinate)
            return zip(points, points.dropFirst()).contains {
                EnvironmentalExposureModel.distance(from: p, toSegment: $0, $1) <= EnvironmentalWeights.intersectionCaptureRadius
            }
        }

        return RouteExposure(
            averageNoiseDb: EnvironmentalWeights.noiseDb(normalized: noiseSum / n),
            peakNoiseDb: EnvironmentalWeights.noiseDb(normalized: peakNoise),
            averageCrowd: crowdSum / n,
            averageTraffic: trafficSum / n,
            averageVisual: visualSum / n,
            highExposureShare: Double(high) / n,
            intersections: intersections,
            eventIds: activeEvents.map(\.id).filter(eventIds.contains),
            corridors: base.corridors.filter { corridor in
                // Counts when at least ~60 m of the route runs inside the corridor's core.
                let path = corridor.path.map(projection.point)
                let inside = points.filter { p in
                    zip(path, path.dropFirst()).contains {
                        EnvironmentalExposureModel.distance(from: p, toSegment: $0, $1) <= corridor.halfWidth
                    }
                }
                return inside.count >= 2 && zip(inside, inside.dropFirst()).reduce(0) { $0 + EnvironmentalExposureModel.length($1.1 - $1.0) } >= 60
            }.map(\.name),
            profile: profile,
            segments: segments,
            cost: cost
        )
    }

    /// Least-cost corridor between two points over the same cost surface used to price routes
    /// (Dijkstra on the 12 m grid, 8-connected). Used to steer Apple Maps toward calmer streets.
    func calmCorridor(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D, weights: TriggerWeights) -> [CLLocationCoordinate2D]? {
        let grid = noise
        guard let s = grid.cell(containing: projection.point(start)),
              let t = grid.cell(containing: projection.point(end)) else { return nil }

        let pad = Int(600 / grid.cellSize)
        let c0 = max(1, min(s.column, t.column) - pad), c1 = min(grid.columns - 2, max(s.column, t.column) + pad)
        let r0 = max(1, min(s.row, t.row) - pad), r1 = min(grid.rows - 2, max(s.row, t.row) + pad)
        let width = c1 - c0 + 1, height = r1 - r0 + 1
        func local(_ column: Int, _ row: Int) -> Int { (row - r0) * width + (column - c0) }

        var stepCost = [Double](repeating: 0, count: width * height)
        for row in r0...r1 {
            for column in c0...c1 {
                stepCost[local(column, row)] = 1 + penalty(cell: row * grid.columns + column, weights)
            }
        }

        var distance = [Double](repeating: .infinity, count: width * height)
        var previous = [Int32](repeating: -1, count: width * height)
        var heap = MinHeap()
        let source = local(s.column, s.row), target = local(t.column, t.row)
        distance[source] = 0
        heap.push(0, source)
        let neighbors: [(Int, Int, Double)] = [
            (1, 0, 1), (-1, 0, 1), (0, 1, 1), (0, -1, 1),
            (1, 1, 2.0.squareRoot()), (1, -1, 2.0.squareRoot()), (-1, 1, 2.0.squareRoot()), (-1, -1, 2.0.squareRoot())
        ]
        while let top = heap.pop() {
            let (d, current) = top
            if current == target { break }
            guard d <= distance[current] else { continue }
            let column = current % width, row = current / width
            for (dx, dy, length) in neighbors {
                let nc = column + dx, nr = row + dy
                guard nc >= 0, nr >= 0, nc < width, nr < height else { continue }
                let next = nr * width + nc
                let candidate = d + length * grid.cellSize * (stepCost[current] + stepCost[next]) / 2
                if candidate < distance[next] {
                    distance[next] = candidate
                    previous[next] = Int32(current)
                    heap.push(candidate, next)
                }
            }
        }
        guard distance[target].isFinite else { return nil }

        var path: [CLLocationCoordinate2D] = []
        var node = target
        while node >= 0 {
            let column = node % width + c0, row = node / width + r0
            path.append(projection.coordinate(grid.center(column: column, row: row)))
            node = Int(previous[node])
        }
        return path.reversed()
    }

    /// Lowest-cost point on a minor street near `coordinate`.
    func calmWaypoint(near coordinate: CLLocationCoordinate2D, searchRadius: CLLocationDistance, weights: TriggerWeights) -> CLLocationCoordinate2D? {
        let target = projection.point(coordinate)
        var best: (point: SIMD2<Double>, score: Double)?
        for anchor in base.streetAnchors {
            let d = EnvironmentalExposureModel.length(anchor - target)
            guard d <= searchRadius else { continue }
            let score = weights.overall(penalty: penalty(at: anchor, weights)) + d / searchRadius * 0.2
            if best == nil || score < best!.score { best = (anchor, score) }
        }
        return best.map { projection.coordinate($0.point) }
    }
}

/// Binary min-heap keyed by distance, for the corridor search.
nonisolated struct MinHeap {
    private var items: [(Double, Int)] = []

    mutating func push(_ key: Double, _ value: Int) {
        items.append((key, value))
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard items[child].0 < items[parent].0 else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> (Double, Int)? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let top = items.removeLast()
        var parent = 0
        while true {
            let left = parent * 2 + 1, right = left + 1
            var smallest = parent
            if left < items.count, items[left].0 < items[smallest].0 { smallest = left }
            if right < items.count, items[right].0 < items[smallest].0 { smallest = right }
            guard smallest != parent else { break }
            items.swapAt(parent, smallest)
            parent = smallest
        }
        return top
    }
}

// MARK: - Contours

/// Marching-squares iso-contours of the exposure raster, assembled into polygons with holes,
/// simplified and smoothed for display.
private nonisolated struct Ring {
    let points: [SIMD2<Double>]
    let area: Double
    let minP: SIMD2<Double>
    let maxP: SIMD2<Double>
}

nonisolated enum ContourTracer {
    static func polygons(in grid: ExposureGrid, threshold t: Double, projection: LocalProjection) -> [ExposureContourBand.Polygon] {
        let nx = grid.columns, ny = grid.rows
        var adjacency: [Int: [Int]] = [:]

        func hKey(_ i: Int, _ j: Int) -> Int { (j * nx + i) * 2 }
        func vKey(_ i: Int, _ j: Int) -> Int { (j * nx + i) * 2 + 1 }
        func link(_ a: Int, _ b: Int) {
            adjacency[a, default: []].append(b)
            adjacency[b, default: []].append(a)
        }
        func position(_ key: Int) -> SIMD2<Double> {
            let cell = key >> 1
            let i = cell % nx, j = cell / nx
            let vertical = key & 1 == 1
            let va = grid[i, j]
            let vb = vertical ? grid[i, j + 1] : grid[i + 1, j]
            let f = vb == va ? 0.5 : min(1, max(0, (t - va) / (vb - va)))
            return SIMD2(
                grid.originX + (Double(i) + (vertical ? 0 : f)) * grid.cellSize,
                grid.originY + (Double(j) + (vertical ? f : 0)) * grid.cellSize
            )
        }

        for j in 0..<(ny - 1) {
            for i in 0..<(nx - 1) {
                let a = grid[i, j], b = grid[i + 1, j], c = grid[i + 1, j + 1], d = grid[i, j + 1]
                let index = (a >= t ? 1 : 0) | (b >= t ? 2 : 0) | (c >= t ? 4 : 0) | (d >= t ? 8 : 0)
                guard index != 0, index != 15 else { continue }
                let e0 = hKey(i, j), e1 = vKey(i + 1, j), e2 = hKey(i, j + 1), e3 = vKey(i, j)
                let centerInside = (a + b + c + d) / 4 >= t
                switch index {
                case 1, 14: link(e3, e0)
                case 2, 13: link(e0, e1)
                case 3, 12: link(e3, e1)
                case 4, 11: link(e1, e2)
                case 6, 9: link(e0, e2)
                case 7, 8: link(e3, e2)
                case 5:
                    if centerInside { link(e0, e1); link(e2, e3) } else { link(e3, e0); link(e1, e2) }
                case 10:
                    if centerInside { link(e3, e0); link(e1, e2) } else { link(e0, e1); link(e2, e3) }
                default: break
                }
            }
        }

        // Chain edge crossings into closed rings.
        var visited = Set<Int>()
        var rings: [[SIMD2<Double>]] = []
        for start in adjacency.keys where !visited.contains(start) {
            var keys = [start]
            visited.insert(start)
            var previous = start
            guard var current = adjacency[start]?.first else { continue }
            while current != start, !visited.contains(current) {
                visited.insert(current)
                keys.append(current)
                guard let neighbors = adjacency[current], neighbors.count >= 2 else { break }
                let next = neighbors[0] == previous ? neighbors[1] : neighbors[0]
                previous = current
                current = next
            }
            if keys.count >= 4 { rings.append(keys.map(position)) }
        }

        // Nest rings: even containment depth = exterior, odd = hole of its smallest container.
        let measured = rings.map { points -> Ring in
            var area = 0.0
            var minP = points[0], maxP = points[0]
            for (index, p) in points.enumerated() {
                let q = points[(index + 1) % points.count]
                area += p.x * q.y - q.x * p.y
                minP = SIMD2(min(minP.x, p.x), min(minP.y, p.y))
                maxP = SIMD2(max(maxP.x, p.x), max(maxP.y, p.y))
            }
            // Exteriors wind counter-clockwise and holes clockwise (fixed below), so holes render
            // correctly under both even-odd and non-zero fill rules.
            let counterClockwise = area > 0 ? points : points.reversed()
            return Ring(points: counterClockwise, area: abs(area) / 2, minP: minP, maxP: maxP)
        }.sorted { $0.area > $1.area }

        var depth = [Int](repeating: 0, count: measured.count)
        var parent = [Int?](repeating: nil, count: measured.count)
        for (index, ring) in measured.enumerated() {
            let probe = ring.points[0]
            for candidate in stride(from: index - 1, through: 0, by: -1) {
                let other = measured[candidate]
                guard probe.x >= other.minP.x, probe.x <= other.maxP.x,
                      probe.y >= other.minP.y, probe.y <= other.maxP.y,
                      contains(probe, in: other.points) else { continue }
                depth[index] += 1
                if parent[index] == nil { parent[index] = candidate }
            }
        }

        var holes: [Int: [[SIMD2<Double>]]] = [:]
        for index in measured.indices where depth[index] % 2 == 1 {
            guard let owner = parent[index], measured[index].area >= 250 else { continue }
            holes[owner, default: []].append(measured[index].points.reversed())
        }

        func display(_ points: [SIMD2<Double>]) -> [CLLocationCoordinate2D] {
            smooth(simplify(points, tolerance: 2.5)).map(projection.coordinate)
        }

        return measured.indices.compactMap { index in
            guard depth[index] % 2 == 0, measured[index].area >= 400 else { return nil }
            return ExposureContourBand.Polygon(
                exterior: display(measured[index].points),
                holes: (holes[index] ?? []).map(display)
            )
        }
    }

    private static func contains(_ p: SIMD2<Double>, in polygon: [SIMD2<Double>]) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Douglas–Peucker on a closed ring.
    private static func simplify(_ ring: [SIMD2<Double>], tolerance: Double) -> [SIMD2<Double>] {
        guard ring.count > 8 else { return ring }
        var keep = [Bool](repeating: false, count: ring.count)
        keep[0] = true
        keep[ring.count - 1] = true
        var stack = [(0, ring.count - 1)]
        while let range = stack.popLast() {
            let (first, last) = range
            guard last > first + 1 else { continue }
            var maxDistance = 0.0, maxIndex = first
            for index in (first + 1)..<last {
                let d = EnvironmentalExposureModel.distance(from: ring[index], toSegment: ring[first], ring[last])
                if d > maxDistance { maxDistance = d; maxIndex = index }
            }
            if maxDistance > tolerance {
                keep[maxIndex] = true
                stack.append((first, maxIndex))
                stack.append((maxIndex, last))
            }
        }
        let simplified = ring.indices.filter { keep[$0] }.map { ring[$0] }
        return simplified.count >= 4 ? simplified : ring
    }

    /// Two passes of Chaikin corner cutting for soft, organic edges.
    private static func smooth(_ ring: [SIMD2<Double>]) -> [SIMD2<Double>] {
        var points = ring
        for _ in 0..<2 {
            var next: [SIMD2<Double>] = []
            next.reserveCapacity(points.count * 2)
            for index in points.indices {
                let a = points[index], b = points[(index + 1) % points.count]
                next.append(a * 0.75 + b * 0.25)
                next.append(a * 0.25 + b * 0.75)
            }
            points = next
        }
        return points
    }
}
