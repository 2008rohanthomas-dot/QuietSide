import Foundation
import MapKit
import Observation

/// Owns the single environmental dataset. Builds the base field once off the main thread,
/// keeps a snapshot for the current time (re-derived when an event starts or ends), and
/// caches the heatmap overlays for every layer.
@Observable
final class EnvironmentStore {
    static let shared = EnvironmentStore()

    private(set) var model: EnvironmentalExposureModel?
    private(set) var snapshot: EnvironmentSnapshot?
    private(set) var overlays: [EnvironmentalLayer: [ExposureBandOverlay]] = [:]
    private(set) var weights = SensoryProfile.load().weights

    /// Fixed time of day for previewing the event schedule; nil follows the real clock.
    private(set) var timeOverride: Date?
    /// Advances every 30 s so time-derived views refresh.
    private(set) var tick = 0
    @ObservationIgnored private var loading: Task<EnvironmentalExposureModel?, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var overlayGeneration = 0

    var now: Date {
        _ = tick
        return timeOverride ?? Date()
    }

    func setTime(_ date: Date?) {
        timeOverride = date
        Task { await currentSnapshot() }
    }

    /// The field for right now, loading it on first use.
    @discardableResult
    func currentSnapshot() async -> EnvironmentSnapshot? {
        guard let model = await loadModel() else { return nil }
        let date = now
        let activeIDs = CampusEventCatalog.active(at: date).map(\.id)
        if let snapshot, snapshot.activeEvents.map(\.id) == activeIDs { return snapshot }
        let fresh = model.snapshot(at: date)
        snapshot = fresh
        rebuildOverlays()
        return fresh
    }

    /// Starts loading and keeps event state current while the app runs.
    func start() async {
        await currentSnapshot()
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.tick += 1
                await self?.currentSnapshot()
            }
        }
    }

    func update(weights newWeights: TriggerWeights) {
        guard newWeights != weights else { return }
        weights = newWeights
        rebuildOverlays()
    }

    private func loadModel() async -> EnvironmentalExposureModel? {
        if let model { return model }
        let task = loading ?? Task.detached(priority: .userInitiated) {
            EnvironmentalExposureModel.loadBundled()
        }
        loading = task
        let loaded = await task.value
        if model == nil { model = loaded }
        return loaded
    }

    private func rebuildOverlays() {
        guard let snapshot else { return }
        overlayGeneration += 1
        let generation = overlayGeneration
        let weights = weights
        Task {
            let bands = await Task.detached(priority: .userInitiated) {
                EnvironmentalLayer.allCases.map { ($0, snapshot.contours(for: $0, weights: weights)) }
            }.value
            guard generation == overlayGeneration else { return }
            var built: [EnvironmentalLayer: [ExposureBandOverlay]] = [:]
            for (layer, layerBands) in bands {
                built[layer] = layerBands.flatMap { band in
                    band.polygons.enumerated().map { index, shape in
                        ExposureBandOverlay(
                            id: "\(generation)-\(layer.rawValue)-\(band.level)-\(index)",
                            level: band.level,
                            polygon: MKPolygon(
                                coordinates: shape.exterior,
                                count: shape.exterior.count,
                                interiorPolygons: shape.holes.map { MKPolygon(coordinates: $0, count: $0.count) }
                            )
                        )
                    }
                }
            }
            overlays = built
        }
    }
}

struct ExposureBandOverlay: Identifiable {
    let id: String
    let level: Int
    let polygon: MKPolygon
}
