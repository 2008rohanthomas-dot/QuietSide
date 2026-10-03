import CoreLocation
import Observation

@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    enum Quality: Equatable {
        case waiting
        case good(meters: Int)
        case poor(meters: Int)
        case denied
        case restricted
        case unavailable

        var label: String {
            switch self {
            case .waiting: "Finding your location…"
            case .good(let meters): "Location accurate to about \(meters) m"
            case .poor(let meters): "Weak location accuracy · ±\(meters) m"
            case .denied: "Location access is off"
            case .restricted: "Location access is restricted"
            case .unavailable: "Location is unavailable"
            }
        }

        var symbol: String {
            switch self {
            case .good: "location.fill"
            case .waiting: "location.circle"
            case .poor: "location.slash.circle"
            case .denied, .restricted, .unavailable: "location.slash.fill"
            }
        }
    }

    private let manager = CLLocationManager()
    private var timeoutTask: Task<Void, Never>?
    private(set) var latestLocation: CLLocation?
    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var quality: Quality = .waiting
    private(set) var isUpdating = false

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.activityType = .otherNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 2
        manager.pausesLocationUpdatesAutomatically = true
    }

    func requestPermissionAndStart() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            start()
        case .denied:
            quality = .denied
        case .restricted:
            quality = .restricted
        @unknown default:
            quality = .unavailable
        }
    }

    func start() {
        manager.startUpdatingLocation()
        isUpdating = true
        if latestLocation == nil { quality = .waiting }
        scheduleTimeout()
    }

    func startNavigationUpdates() {
        manager.activityType = .otherNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 2
        manager.pausesLocationUpdatesAutomatically = false
        start()
    }

    func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil
        manager.stopUpdatingLocation()
        isUpdating = false
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            start()
        case .denied:
            quality = .denied
            stop()
        case .restricted:
            quality = .restricted
            stop()
        case .notDetermined:
            quality = .waiting
        @unknown default:
            quality = .unavailable
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let candidate = locations.last else { return }
        let age = abs(candidate.timestamp.timeIntervalSinceNow)
        guard candidate.horizontalAccuracy >= 0, age <= 10 else { return }

        let roundedAccuracy = Int(candidate.horizontalAccuracy.rounded())
        guard candidate.horizontalAccuracy <= 65 else {
            quality = .poor(meters: roundedAccuracy)
            return
        }

        if let previous = latestLocation {
            let elapsed = max(candidate.timestamp.timeIntervalSince(previous.timestamp), 0.1)
            let impliedSpeed = candidate.distance(from: previous) / elapsed
            if impliedSpeed > 8, candidate.horizontalAccuracy > 12 { return }
        }

        latestLocation = candidate
        timeoutTask?.cancel()
        timeoutTask = nil
        quality = candidate.horizontalAccuracy <= 25
            ? .good(meters: roundedAccuracy)
            : .poor(meters: roundedAccuracy)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard let locationError = error as? CLError else {
            quality = .unavailable
            return
        }
        switch locationError.code {
        case .denied:
            quality = .denied
            stop()
        case .locationUnknown:
            break
        default:
            quality = .unavailable
        }
    }

    private func scheduleTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.latestLocation == nil else { return }
            self.quality = .unavailable
        }
    }
}
