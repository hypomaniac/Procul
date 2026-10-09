import Foundation
import UserNotifications

/// The "Apple TV wants text" notification. Off unless this Mac asked for it.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Called when the notification is clicked.
    var onOpen: (() -> Void)?

    private static let identifier = "text-wanted"

    /// Notifications need a real app bundle. A bare debug binary has none.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func start() {
        center?.delegate = self
    }

    /// Asks macOS for permission. Reports whether notifications can be shown.
    func requestPermission(_ done: @escaping @MainActor (Bool) -> Void) {
        guard let center else {
            done(false)
            return
        }
        center.requestAuthorization(options: [.alert]) { granted, _ in
            Task { @MainActor in done(granted) }
        }
    }

    func textWanted(on device: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(device) wants text"
        content.body = "Click to type it from this Mac."
        center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
    }

    func clear() {
        center?.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run { onOpen?() }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}
