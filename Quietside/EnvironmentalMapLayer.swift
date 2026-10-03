import SwiftUI
import MapKit
import Observation

// MARK: - Layer settings

@MainActor
@Observable
final class MapLayerSettings {
    static let shared = MapLayerSettings()

    var layer: EnvironmentalLayer { didSet { UserDefaults.standard.set(layer.rawValue, forKey: "layer.selected") } }
    var showsHeatmap: Bool { didSet { UserDefaults.standard.set(showsHeatmap, forKey: "layer.heatmap") } }
    var showsMarkers: Bool { didSet { UserDefaults.standard.set(showsMarkers, forKey: "layer.markers") } }

    private init() {
        let defaults = UserDefaults.standard
        layer = defaults.string(forKey: "layer.selected").flatMap(EnvironmentalLayer.init(rawValue:)) ?? .overall
        showsHeatmap = defaults.object(forKey: "layer.heatmap") as? Bool ?? true
        showsMarkers = defaults.object(forKey: "layer.markers") as? Bool ?? true
    }
}

// MARK: - Palette

enum ExposurePalette {
    private static let stops: [(value: Double, rgb: (Double, Double, Double))] = [
        (0.00, (0.55, 0.78, 0.62)),
        (0.25, (0.96, 0.80, 0.36)),
        (0.45, (0.94, 0.58, 0.25)),
        (0.70, (0.84, 0.28, 0.21)),
        (1.00, (0.60, 0.10, 0.15))
    ]

    static func color(for value: Double) -> Color {
        let v = min(1, max(0, value))
        guard let upper = stops.firstIndex(where: { $0.value >= v }), upper > 0 else {
            let rgb = stops[0].rgb
            return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
        }
        let a = stops[upper - 1], b = stops[upper]
        let t = (v - a.value) / (b.value - a.value)
        return Color(
            red: a.rgb.0 + (b.rgb.0 - a.rgb.0) * t,
            green: a.rgb.1 + (b.rgb.1 - a.rgb.1) * t,
            blue: a.rgb.2 + (b.rgb.2 - a.rgb.2) * t
        )
    }

    static let legendGradient = LinearGradient(
        colors: [0.0, 0.25, 0.5, 0.75, 1.0].map(color(for:)),
        startPoint: .leading,
        endPoint: .trailing
    )

    /// Band fills stack, so each level is individually faint; the map stays readable.
    static func bandColor(level: Int) -> Color {
        let thresholds = EnvironmentalExposureModel.bandThresholds
        return color(for: thresholds[min(level, thresholds.count - 1)] + 0.1)
    }

    static func bandOpacity(level: Int) -> Double { [0.15, 0.15, 0.16, 0.18, 0.21][min(level, 4)] }

    static let signal = QSColor.ink
    static let event = Color(red: 0.55, green: 0.25, blue: 0.75)
}

// MARK: - Map content

/// The heatmap for the selected layer plus crossings and event areas, all from `EnvironmentStore`.
struct EnvironmentalMapLayer: MapContent {
    let store: EnvironmentStore
    let settings: MapLayerSettings
    /// Fades the field further, e.g. during turn-by-turn.
    var fieldOpacity: Double = 1

    var body: some MapContent {
        if settings.showsHeatmap {
            ForEach(store.overlays[settings.layer] ?? []) { band in
                MapPolygon(band.polygon)
                    .foregroundStyle(ExposurePalette.bandColor(level: band.level)
                        .opacity(ExposurePalette.bandOpacity(level: band.level) * fieldOpacity))
                    .mapOverlayLevel(level: .aboveRoads)
            }
        }
        if settings.showsMarkers {
            if settings.layer == .traffic || settings.layer == .overall {
                ForEach(CampustownStimuli.intersections) { stimulus in
                    Annotation(stimulus.label, coordinate: stimulus.coordinate, anchor: .center) {
                        IntersectionStimulusMarker(intensity: stimulus.intensity)
                    }
                    .annotationTitles(.hidden)
                }
            }
            ForEach(CampusEventCatalog.all.filter { $0.status(at: store.now) != .ended }) { event in
                let active = event.status(at: store.now) == .active
                if active {
                    MapCircle(center: event.center, radius: event.radius)
                        .foregroundStyle(ExposurePalette.event.opacity(0.12))
                        .stroke(ExposurePalette.event.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
                if !active, event.start.timeIntervalSince(store.now) <= 4 * 3600 {
                    MapCircle(center: event.center, radius: event.radius)
                        .foregroundStyle(ExposurePalette.event.opacity(0.04))
                        .stroke(ExposurePalette.event.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                }
                Annotation(event.area, coordinate: event.center, anchor: .center) {
                    VStack(spacing: 3) {
                        EventMarker(event: event, active: active)
                        Text(active ? "Live" : event.start.formatted(CampusEventCatalog.timeStyle))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(active ? .white : ExposurePalette.event)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(active ? AnyShapeStyle(ExposurePalette.event) : AnyShapeStyle(.thickMaterial), in: Capsule())
                    }
                }
                .annotationTitles(.hidden)
            }
        }
    }
}

/// A route drawn in pieces, each colored by the selected layer's value at that stretch.
struct ExposureRouteLine: MapContent {
    let candidate: RouteCandidate
    let layer: EnvironmentalLayer
    var selected = true

    var body: some MapContent {
        if selected {
            MapPolyline(candidate.route.polyline)
                .stroke(.white, style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round))
            MapPolyline(candidate.route.polyline)
                .stroke(QSColor.route(candidate.kind), style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
            ForEach(Array(candidate.exposure.segments.enumerated()), id: \.offset) { _, segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(
                        ExposurePalette.color(for: segment.value(for: layer)),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                    )
            }
        } else {
            MapPolyline(candidate.route.polyline)
                .stroke(
                    QSColor.route(candidate.kind).opacity(0.7),
                    style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round, dash: [1, 8])
                )
        }
    }
}

/// The simulated current location.
struct OriginMarker: View {
    var body: some View {
        ZStack {
            Circle().fill(QSColor.routeFast.opacity(0.18)).frame(width: 30, height: 30)
            Circle().fill(.white).frame(width: 17, height: 17)
            Circle().fill(QSColor.routeFast).frame(width: 12, height: 12)
        }
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        .accessibilityLabel("Current location, CIF")
    }
}

struct IntersectionStimulusMarker: View {
    let intensity: EnvironmentalStimulus.Intensity

    var body: some View {
        ZStack {
            Circle()
                .fill(ExposurePalette.signal.opacity(0.12))
                .frame(width: intensity == .high ? 18 : 14, height: intensity == .high ? 18 : 14)
            Circle()
                .fill(.white)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(ExposurePalette.signal, lineWidth: 2))
        }
        .accessibilityHidden(true)
    }
}

struct EventMarker: View {
    let event: CampusEvent
    let active: Bool

    var body: some View {
        Image(systemName: event.symbol)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(active ? .white : ExposurePalette.event)
            .frame(width: 28, height: 28)
            .background(active ? AnyShapeStyle(ExposurePalette.event) : AnyShapeStyle(.thickMaterial), in: Circle())
            .overlay(Circle().stroke(ExposurePalette.event, lineWidth: active ? 0 : 1.5))
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            .accessibilityLabel(event.name)
    }
}

// MARK: - Chrome

/// Noise / Crowd / Traffic / Overall switcher with a compact legend.
struct LayerPicker: View {
    @Bindable var settings: MapLayerSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                ForEach(EnvironmentalLayer.allCases) { layer in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { settings.layer = layer }
                    } label: {
                        Text(layer.title)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundStyle(settings.layer == layer ? .white : .primary)
                            .background(settings.layer == layer ? QSColor.ink : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            if settings.showsHeatmap {
                HStack(spacing: 6) {
                    Text(settings.layer.lowLabel)
                    Capsule().fill(ExposurePalette.legendGradient).frame(height: 5)
                    Text(settings.layer.highLabel)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            }
        }
        .padding(4)
        .padding(.bottom, settings.showsHeatmap ? 4 : 0)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 1))
        .fixedSize()
    }
}

struct MapLayerMenu: View {
    @Bindable var settings: MapLayerSettings

    var body: some View {
        Menu {
            Toggle(isOn: $settings.showsHeatmap) { Label("Heatmap", systemImage: "aqi.medium") }
            Toggle(isOn: $settings.showsMarkers) { Label("Crossings & events", systemImage: "mappin.and.ellipse") }
        } label: {
            MapControlIcon(systemImage: "square.3.layers.3d")
        }
        .accessibilityLabel("Map layers")
    }
}

/// Live time by default; presets jump to points in today's event schedule.
struct EventClockMenu: View {
    let store: EnvironmentStore

    var body: some View {
        Menu {
            Button { store.setTime(nil) } label: {
                Label("Live time", systemImage: store.timeOverride == nil ? "checkmark" : "clock")
            }
            Section("Today") {
                ForEach(CampusEventCatalog.all) { event in
                    let preview = event.start.addingTimeInterval(45 * 60)
                    Button {
                        store.setTime(preview)
                    } label: {
                        Text("\(preview.formatted(CampusEventCatalog.timeStyle)) · \(event.name)")
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "clock")
                Text(store.now.formatted(CampusEventCatalog.timeStyle))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(store.timeOverride == nil ? Color.primary : ExposurePalette.event)
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(.thickMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.06), lineWidth: 1))
        }
        .accessibilityLabel("Time")
    }
}

struct MapControlIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 36, height: 36)
            .background(.thickMaterial, in: Circle())
            .overlay(Circle().stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

/// Exposure along a route, start → destination, using the same colour ramp as the map.
struct ExposureStrip: View {
    let segments: [RouteExposureSegment]
    let layer: EnvironmentalLayer

    var body: some View {
        let values = segments.map { $0.value(for: layer) }
        Capsule()
            .fill(LinearGradient(
                stops: values.enumerated().map { index, value in
                    .init(color: ExposurePalette.color(for: value),
                          location: values.count > 1 ? Double(index) / Double(values.count - 1) : 0)
                },
                startPoint: .leading,
                endPoint: .trailing
            ))
            .frame(height: 7)
            .accessibilityLabel("\(layer.title) along route")
    }
}
