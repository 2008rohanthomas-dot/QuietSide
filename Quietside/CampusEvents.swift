import Foundation
import CoreLocation

/// A scheduled campus event that raises environmental exposure around its area while active.
nonisolated struct CampusEvent: Identifiable, Sendable {
    nonisolated enum Status: Sendable { case upcoming, active, ended }

    /// Added on top of the base field while the event is active (0…1 each).
    nonisolated struct Effects: Sendable {
        let crowd: Double
        let noise: Double
        let traffic: Double
        let visual: Double
    }

    let id: String
    let name: String
    let area: String
    let start: Date
    let end: Date
    let center: CLLocationCoordinate2D
    /// Full-strength radius; influence fades smoothly beyond it.
    let radius: CLLocationDistance
    let effects: Effects
    let symbol: String

    /// "Extreme" or "High", from the strongest effect.
    var intensityLabel: String {
        max(effects.crowd, effects.noise) >= 0.95 ? "Extreme" : "High"
    }

    /// True when any point of the path is inside the event's strong-influence area.
    func touches(_ path: [CLLocationCoordinate2D]) -> Bool {
        let center = CLLocation(latitude: self.center.latitude, longitude: self.center.longitude)
        return path.contains {
            influence(atDistance: center.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))) > 0.3
        }
    }

    /// "in 2h 10m" / "in 25 min".
    func countdown(from date: Date) -> String {
        let minutes = max(0, Int(start.timeIntervalSince(date) / 60))
        return minutes >= 60 ? "in \(minutes / 60)h \(minutes % 60)m" : "in \(minutes) min"
    }

    func status(at date: Date) -> Status {
        if date < start { return .upcoming }
        if date < end { return .active }
        return .ended
    }

    /// 0…1 influence at a distance from the event center.
    func influence(atDistance distance: CLLocationDistance) -> Double {
        guard distance > radius else { return 1 }
        let sigma = radius * 0.55
        let beyond = (distance - radius) / sigma
        return exp(-0.5 * beyond * beyond)
    }

    var reach: CLLocationDistance { radius + radius * 0.55 * 3 }

    var timeRange: String {
        "\(start.formatted(CampusEventCatalog.timeStyle))–\(end.formatted(CampusEventCatalog.timeStyle))"
    }
}

nonisolated enum CampusEventCatalog {
    static let centralTime = TimeZone(identifier: "America/Chicago")!

    /// Saturday, October 3, 2026 — Illinois Homecoming.
    static let all: [CampusEvent] = [
        CampusEvent(
            id: "grange-grove-tailgate",
            name: "Grange Grove Tailgating",
            area: "Grange Grove",
            start: time(11, 0),
            end: time(15, 15),
            center: CLLocationCoordinate2D(latitude: 40.09939, longitude: -88.23794),
            radius: 170,
            effects: .init(crowd: 0.85, noise: 0.7, traffic: 0.5, visual: 0.45),
            symbol: "music.note"
        ),
        CampusEvent(
            id: "homecoming-football",
            name: "Illinois vs. Purdue",
            area: "Gies Memorial Stadium",
            start: time(15, 15),
            end: time(18, 45),
            center: CLLocationCoordinate2D(latitude: 40.09916, longitude: -88.23599),
            radius: 330,
            effects: .init(crowd: 1.0, noise: 1.0, traffic: 0.9, visual: 0.75),
            symbol: "sportscourt.fill"
        ),
        CampusEvent(
            id: "homecoming-saturday-night-live",
            name: "Homecoming Saturday Night LIVE",
            area: "Downtown Champaign",
            start: time(18, 0),
            end: time(21, 0),
            center: CLLocationCoordinate2D(latitude: 40.11634, longitude: -88.24353),
            radius: 220,
            effects: .init(crowd: 0.8, noise: 0.8, traffic: 0.3, visual: 0.65),
            symbol: "music.mic"
        )
    ]

    /// "3:15 PM" in Central Time.
    static var timeStyle: Date.FormatStyle {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = centralTime
        return style
    }

    /// The live event, else the next one starting within `horizon`.
    static func headline(at date: Date, horizon: TimeInterval = 4 * 3600) -> CampusEvent? {
        all.first { $0.status(at: date) == .active }
            ?? all.filter { $0.status(at: date) == .upcoming && $0.start.timeIntervalSince(date) <= horizon }
                .min { $0.start < $1.start }
    }

    static func active(at date: Date) -> [CampusEvent] {
        all.filter { $0.status(at: date) == .active }
    }

    private static func time(_ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = centralTime
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: hour, minute: minute))!
    }
}
