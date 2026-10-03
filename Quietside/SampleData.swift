import Foundation
import MapKit

#if DEBUG
enum PreviewFixtures {
    static let campusCenter = CLLocationCoordinate2D(latitude: 40.1107, longitude: -88.2272)

    static let grainger = Place(
        id: "preview-grainger",
        name: "Grainger Engineering Library",
        subtitle: "Library · UIUC",
        latitude: 40.1124,
        longitude: -88.2269
    )
}
#endif
