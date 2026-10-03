import MapKit
import Observation

@MainActor
@Observable
final class NavigationSession {
    private(set) var candidate: RouteCandidate
    private(set) var progress: NavigationProgress?
    private(set) var isRerouting = false
    private(set) var rerouteGeneration = 0
    private(set) var arrived = false
    private var previousAlongDistance: CLLocationDistance?
    private var consecutiveOffRouteFixes = 0

    init(candidate: RouteCandidate) {
        self.candidate = candidate
    }

    var currentStep: WalkingRoute.Step? {
        guard !candidate.route.steps.isEmpty else { return nil }
        let index = min(progress?.currentStepIndex ?? 0, candidate.route.steps.count - 1)
        return candidate.route.steps[index]
    }

    func update(with location: CLLocation) {
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 25,
              abs(location.timestamp.timeIntervalSinceNow) <= 10,
              let match = PolylineGeometry.nearestMatch(
                to: location.coordinate,
                on: candidate.route.polyline,
                previousProgress: previousAlongDistance
              ) else { return }

        let fraction = match.totalDistance > 0
            ? min(1, max(0, match.alongRouteDistance / match.totalDistance))
            : 0
        let routedDistance = candidate.route.distance * fraction
        let remainingDistance = max(0, candidate.route.distance - routedDistance)
        let remainingTime = candidate.route.expectedTravelTime * (1 - fraction)
        let stepResult = stepIndexAndRemaining(for: routedDistance)

        if match.distanceToLine >= 30 {
            consecutiveOffRouteFixes += 1
        } else {
            consecutiveOffRouteFixes = 0
        }
        let isOffRoute = consecutiveOffRouteFixes >= 3
        if isOffRoute, !isRerouting {
            rerouteGeneration += 1
            consecutiveOffRouteFixes = 0
        }

        previousAlongDistance = max(previousAlongDistance ?? 0, match.alongRouteDistance)
        arrived = remainingDistance <= 15
        progress = NavigationProgress(
            snappedCoordinate: match.coordinate,
            distanceToRoute: match.distanceToLine,
            fractionComplete: fraction,
            remainingDistance: remainingDistance,
            remainingTime: remainingTime,
            currentStepIndex: stepResult.index,
            distanceToManeuver: stepResult.remaining,
            isOffRoute: isOffRoute
        )
    }

    func reroute(from location: CLLocation, to destination: MKMapItem, profile: SensoryProfile) async {
        guard !isRerouting else { return }
        isRerouting = true
        defer { isRerouting = false }
        do {
            let options = try await RouteService().candidates(
                from: location.coordinate,
                to: destination,
                profile: profile
            )
            let replacement = options.first(where: { $0.kind == candidate.kind }) ?? options.first
            guard let replacement else { return }
            candidate = replacement
            progress = nil
            previousAlongDistance = nil
            consecutiveOffRouteFixes = 0
        } catch {
            // Preserve the previous route. A later accurate off-route sequence can retry.
        }
    }

    private func stepIndexAndRemaining(for routeDistance: CLLocationDistance) -> (index: Int, remaining: CLLocationDistance) {
        let steps = candidate.route.steps
        guard !steps.isEmpty else { return (0, max(0, candidate.route.distance - routeDistance)) }
        var cumulative: CLLocationDistance = 0
        for (index, step) in steps.enumerated() {
            cumulative += step.distance
            if routeDistance <= cumulative {
                return (index, max(0, cumulative - routeDistance))
            }
        }
        return (steps.count - 1, 0)
    }
}
