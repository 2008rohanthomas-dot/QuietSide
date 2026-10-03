import Foundation
import Observation
import UserNotifications

/// Local alerts 30 minutes before an event's area turns high-stimulation.
/// Notification permission is only requested when the user turns a reminder on.
@MainActor
@Observable
final class EventReminders: NSObject, UNUserNotificationCenterDelegate {
    static let shared = EventReminders()
    static let leadTime: TimeInterval = 30 * 60

    private(set) var scheduled: Set<String> = []
    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        center.delegate = self
        Task { await refresh() }
    }

    func isOn(_ event: CampusEvent) -> Bool { scheduled.contains(event.id) }

    func toggle(_ event: CampusEvent) async {
        if isOn(event) {
            center.removePendingNotificationRequests(withIdentifiers: [event.id])
            scheduled.remove(event.id)
            return
        }
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(event.intensityLabel) stimulation at \(event.area)"
        content.body = "\(event.name) starts at \(event.start.formatted(CampusEventCatalog.timeStyle)). Calmest routes will avoid the area."
        content.sound = .default

        // Fire 30 min ahead, or in a few seconds if that moment has passed.
        let delay = max(5, event.start.addingTimeInterval(-Self.leadTime).timeIntervalSinceNow)
        let request = UNNotificationRequest(
            identifier: event.id,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        )
        do {
            try await center.add(request)
            scheduled.insert(event.id)
        } catch {}
    }

    private func refresh() async {
        let pending = await center.pendingNotificationRequests()
        scheduled = Set(pending.map(\.identifier))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
