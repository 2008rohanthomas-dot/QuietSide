import MapKit

enum PolylineGeometry {
    struct Match {
        let coordinate: CLLocationCoordinate2D
        let distanceToLine: CLLocationDistance
        let alongRouteDistance: CLLocationDistance
        let totalDistance: CLLocationDistance
    }

    static func coordinates(of polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        guard polyline.pointCount > 0 else { return [] }
        var coordinates = Array(
            repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            count: polyline.pointCount
        )
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        return coordinates
    }

    static func nearestMatch(
        to coordinate: CLLocationCoordinate2D,
        on polyline: MKPolyline,
        previousProgress: CLLocationDistance? = nil
    ) -> Match? {
        let coordinates = coordinates(of: polyline)
        guard coordinates.count >= 2 else { return nil }

        let target = MKMapPoint(coordinate)
        var cumulative: CLLocationDistance = 0
        var total: CLLocationDistance = 0
        var segmentLengths: [CLLocationDistance] = []

        for index in 0..<(coordinates.count - 1) {
            let length = MKMapPoint(coordinates[index]).distance(to: MKMapPoint(coordinates[index + 1]))
            segmentLengths.append(length)
            total += length
        }

        var best: (score: Double, point: MKMapPoint, distance: Double, along: Double)?
        for index in 0..<(coordinates.count - 1) {
            let a = MKMapPoint(coordinates[index])
            let b = MKMapPoint(coordinates[index + 1])
            let dx = b.x - a.x
            let dy = b.y - a.y
            let denominator = dx * dx + dy * dy
            let rawT = denominator > 0
                ? ((target.x - a.x) * dx + (target.y - a.y) * dy) / denominator
                : 0
            let t = min(1, max(0, rawT))
            let projected = MKMapPoint(x: a.x + t * dx, y: a.y + t * dy)
            let distance = target.distance(to: projected)
            let along = cumulative + segmentLengths[index] * t

            var score = distance
            if let previousProgress, along < previousProgress - 25 {
                score += (previousProgress - along) * 0.75
            }
            if best == nil || score < best!.score {
                best = (score, projected, distance, along)
            }
            cumulative += segmentLengths[index]
        }

        guard let best else { return nil }
        return Match(
            coordinate: best.point.coordinate,
            distanceToLine: best.distance,
            alongRouteDistance: best.along,
            totalDistance: total
        )
    }
}
