import Foundation
import UserNotifications
import os.log

enum NotificationHelper {
    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.codecraft_studio.messenger.notifications",
                                   category: "Notifications")

    private static let historyKey = "notification_history_map"
    private static let dismissedUntilKey = "dismissed_until_by_room"
    private static let maxMessagesPerRoom = 20

    static func showRoomNotification(title: String,
                                     body: String,
                                     roomId: Int,
                                     messageId: String? = nil,
                                     timestamp: Int64 = 0,
                                     isSync: Bool = false) {
        
        let center = UNUserNotificationCenter.current()
        let identifier = "\(roomId)"
        let threadIdentifier = "room_\(roomId)"
        
        // Add to history for summary logic
        addToHistory(roomId: roomId, title: title, body: body, messageId: messageId, timestamp: timestamp)

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["roomId": roomId, "messageId": messageId ?? ""]
        content.threadIdentifier = threadIdentifier
        content.categoryIdentifier = "CHAT_MESSAGE"

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request) { error in
            if let error = error {
                os_log("❌ Failed to add notification: %{public}@", log: log, type: .error, error.localizedDescription)
            }
        }
    }

    static func clearRoomHistory(roomId: Int) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ["\(roomId)"])
        // Also remove summary if any
        clearHistory(roomId: roomId)
    }

    private static func addToHistory(roomId: Int, title: String, body: String, messageId: String?, timestamp: Int64) {
        // Implementation for history if needed for summaries on iOS.
        // On iOS, system handles grouping by threadIdentifier automatically if supported.
    }

    private static func clearHistory(roomId: Int) {
        // Implementation
    }
}
