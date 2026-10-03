import SwiftUI
import MapKit
import Observation

// MARK: - Store

/// Loads the bundled environmental data once, off the main thread, and caches both the
/// scoring model and its map overlays for every screen.
@Observable
final class EnvironmentStore {
    static let shared = EnvironmentStore()

    private(set) var model: EnvironmentalExposureModel?
    private(set) var bandOverlays: [ExposureBandOverlay] = []
    @ObservationIgnored private var loading: Task<EnvironmentalExposureModel?, Never>?

    @discardableResult
    func load() async -> EnvironmentalExposureModel? {
        if let model { return model }
        let task = loading ?? Task.detached(priority: .userInitiated) {
            EnvironmentalExposureModel.loadBundled()
        }
        loading = task
        let loaded = await task.value
        if model == nil, let loaded {
            bandOverlays = loaded.bands.flatMap { band in
                band.polygons.enumerated().map { index, shape in
                    ExposureBandOverlay(
                        id: band.level * 100_000 + index,
                        level: band.level,
                        polygon: MKPolygon(
                            coordinates: shape.exterior,
                            count: shape.exterior.count,
                            interiorPolygons: shape.holes.map { MKPolygon(coordinates: $0, count: $0.count) }
                        )
                    )
                }
            }
            model = loaded
        }
        return loaded
    }
}

struct ExposureBandOverlay: Identifiable {
    let id: Int
    let level: Int
    let polygon: MKPolygon
}

@Observable
final class MapLayerSettings {
    static let shared = MapLayerSettings()

    var showsExposure: Bool { didSet { UserDefaults.standard.set(showsExposure, forKey: "layer.exposure") } }
    var showsIntersections: Bool { didSet { UserDefaults.standard.set(showsIntersections, forKey: "layer.intersections") } }
    var showsActivity: Bool { didSet { UserDefaults.standard.set(showsActivity, forKey: "layer.activity") } }

    private init() {
        let defaults = UserDefaults.standard
        showsExposure = defaults.object(forKey: "layer.exposure") as? Bool ?? true
        showsIntersections = defaults.object(forKey: "layer.intersections") as? Bool ?? true
        showsActivity = defaults.object(forKey: "layer.activity") as? Bool ?? true
    }
}

// MARK: - Palette

enum ExposurePalette {
    private static let stops: [(value: Double, rgb: (Double, Double, Double))] = [
        (0.00, (0.80, 0.86, 0.80)),
        (0.20, (0.96, 0.80, 0.36)),
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
        let threshold = EnvironmentalExposureModel.bandThresholds[min(level, EnvironmentalExposureModel.bandThresholds.count - 1)]
        return color(for: threshold + 0.1)
    }

    static func bandOpacity(level: Int) -> Double { [0.15, 0.15, 0.16, 0.18, 0.21][min(level, 4)] }

    static let signal = QSColor.ink
    static let visual = Color(red: 0.49, green: 0.36, blue: 0.80)
}

// MARK: - Map content

struct EnvironmentalMapLayer: MapContent {
    let store: EnvironmentStore
    let settings: MapLayerSettings
    /// Fades the field further, e.g. during turn-by-turn.
    var fieldOpacity: Double = 1

    var body: some MapContent {
        if settings.showsExposure {
            ForEach(store.bandOverlays) { band in
                MapPolygon(band.polygon)
                    .foregroundStyle(ExposurePalette.bandColor(level: band.level)
                        .opacity(ExposurePalette.bandOpacity(level: band.level) * fieldOpacity))
                    .mapOverlayLevel(level: .aboveRoads)
            }
        }
        if settings.showsIntersections {
            ForEach(CampustownStimuli.intersections) { stimulus in
                Annotation(stimulus.label, coordinate: stimulus.coordinate, anchor: .center) {
                    IntersectionStimulusMarker(intensity: stimulus.intensity)
                }
                .annotationTitles(.hidden)
            }
        }
        if settings.showsActivity {
            ForEach(CampustownStimuli.visual) { stimulus in
                Annotation(stimulus.label, coordinate: stimulus.coordinate, anchor: .center) {
                    VisualStimulusMarker(intensity: stimulus.intensity)
                }
                .annotationTitles(.hidden)
            }
        }
    }
}

struct IntersectionStimulusMarker: View {
    let intensity: EnvironmentalStimulus.Intensity

    var body: some View {
        ZStack {
            Circle()
                .fill(ExposurePalette.signal.opacity(0.12))
                .frame(width: intensity == .high ? 20 : 15, height: intensity == .high ? 20 : 15)
            Circle()
                .fill(.white)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(ExposurePalette.signal, lineWidth: 2.2))
        }
        .accessibilityHidden(true)
    }
}

struct VisualStimulusMarker: View {
    let intensity: EnvironmentalStimulus.Intensity

    var body: some View {
        ZStack {
            Circle()
                .fill(ExposurePalette.visual.opacity(0.16))
                .frame(width: intensity == .high ? 24 : 18, height: intensity == .high ? 24 : 18)
            DiamondGlyph(size: 9)
        }
        .accessibilityHidden(true)
    }
}

private struct DiamondGlyph: View {
    let size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(ExposurePalette.visual)
            .overlay(RoundedRectangle(cornerRadius: 1.5).stroke(.white, lineWidth: 1.5))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(45))
    }
}

// MARK: - Chrome

struct ExposureLegend: View {
    let settings: MapLayerSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if settings.showsExposure {
                Text("ENVIRONMENTAL EXPOSURE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                Capsule()
                    .fill(ExposurePalette.legendGradient)
                    .frame(width: 132, height: 6)
                HStack {
                    Text("Low")
                    Spacer()
                    Text("High")
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 132)
            }
            if settings.showsIntersections || settings.showsActivity {
                HStack(spacing: 10) {
                    if settings.showsIntersections {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(.white)
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(ExposurePalette.signal, lineWidth: 2))
                            Text("Signal")
                        }
                    }
                    if settings.showsActivity {
                        HStack(spacing: 4) {
                            DiamondGlyph(size: 7)
                            Text("Activity")
                        }
                    }
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Legend: environmental exposure from low to high, signalized crossings, activity hotspots")
    }
}

struct MapLayerMenu: View {
    @Bindable var settings: MapLayerSettings

    var body: some View {
        Menu {
            Toggle(isOn: $settings.showsExposure) {
                Label("Environmental exposure", systemImage: "aqi.medium")
            }
            Toggle(isOn: $settings.showsIntersections) {
                Label("Intersection stimuli", systemImage: "circle.circle")
            }
            Toggle(isOn: $settings.showsActivity) {
                Label("Activity hotspots", systemImage: "diamond.fill")
            }
        } label: {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(.thickMaterial, in: Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.06), lineWidth: 1))
        }
        .accessibilityLabel("Map layers")
    }
}

/// Exposure along a route, start → destination, using the same colour ramp as the map.
struct ExposureStrip: View {
    let profile: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Capsule()
                .fill(LinearGradient(
                    stops: profile.enumerated().map { index, value in
                        .init(color: ExposurePalette.color(for: value),
                              location: profile.count > 1 ? Double(index) / Double(profile.count - 1) : 0)
                    },
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .frame(height: 7)
            HStack {
                Text("Start")
                Spacer()
                Text("Exposure along route")
                Spacer()
                Text("Arrive")
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Exposure along route")
    }
}
