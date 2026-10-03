import MapKit
import Observation

/// Turn-by-turn along a route, driven by a simulated walker that starts at CIF.
@MainActor
@Observable
final class NavigationSession {
    let candidate: RouteCandidate
    /// Simulated seconds per real second.
    static let playbackSpeed: Double = 8

    private(set) var travelled: CLLocationDistance = 0
    private(set) var isPaused = false
    private let coordinates: [CLLocationCoordinate2D]
    private let cumulative: [CLLocationDistance]
    private let length: CLLocationDistance
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init(candidate: RouteCandidate) {
        self.candidate = candidate
        coordinates = PolylineGeometry.coordinates(of: candidate.route.polyline)
        var running: CLLocationDistance = 0
        var cumulative: [CLLocationDistance] = [0]
        for (a, b) in zip(coordinates, coordinates.dropFirst()) {
            running += MKMapPoint(a).distance(to: MKMapPoint(b))
            cumulative.append(running)
        }
        self.cumulative = cumulative
        length = running
    }

    var fractionComplete: Double { length > 0 ? min(1, travelled / length) : 1 }
    var arrived: Bool { fractionComplete >= 1 }
    var remainingDistance: CLLocationDistance { candidate.route.distance * (1 - fractionComplete) }
    var remainingTime: TimeInterval { candidate.route.expectedTravelTime * (1 - fractionComplete) }

    var position: CLLocationCoordinate2D {
        guard coordinates.count >= 2 else { return coordinates.first ?? CampusOrigin.cif.coordinate }
        let index = min(cumulative.count - 2, max(0, (cumulative.firstIndex { $0 > travelled } ?? cumulative.count - 1) - 1))
        let a = coordinates[index], b = coordinates[index + 1]
        let span = cumulative[index + 1] - cumulative[index]
        let t = span > 0 ? min(1, max(0, (travelled - cumulative[index]) / span)) : 0
        return CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * t,
            longitude: a.longitude + (b.longitude - a.longitude) * t
        )
    }

    /// Current step and the distance left until its maneuver.
    var currentStep: (step: WalkingRoute.Step, remaining: CLLocationDistance)? {
        let steps = candidate.route.steps
        guard !steps.isEmpty else { return nil }
        let routed = candidate.route.distance * fractionComplete
        var end: CLLocationDistance = 0
        for (index, step) in steps.enumerated() {
            end += step.distance
            // The zero-length "start" step is skipped once walking begins.
            if routed < end || index == steps.count - 1 {
                let next = index + 1 < steps.count ? steps[index + 1] : step
                return (next, max(0, end - routed))
            }
        }
        return nil
    }

    func start() {
        guard ticker == nil else { return }
        let speed = length / max(candidate.route.expectedTravelTime, 1)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                guard !self.isPaused else { continue }
                self.travelled = min(self.length, self.travelled + speed * 0.25 * Self.playbackSpeed)
                if self.arrived { self.stop() }
            }
        }
    }

    func togglePause() { isPaused.toggle() }

    func stop() {
        ticker?.cancel()
        ticker = nil
    }
}
