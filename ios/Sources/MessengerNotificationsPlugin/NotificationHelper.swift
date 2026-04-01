import Foundation
import UserNotifications

final class NotificationHelper {
    private static let channelId = "chat_messages"
    private static let groupKey = (Bundle.main.bundleIdentifier ?? "com.messenger.plugin") + ".ROOM_GROUP"
    private static let genericNotificationId = 900_000
    private static let maxPersistentIds = 300
    private static let maxMessagesPerRoom = 50

    private static let recentMessageIdsKey = "notification_history.recent_message_ids"
    private static var serverTimeOffset: Int64 = 0

    private static var roomMessages: [Int: [MessageRecord]] = [:]
    private static var recentMessageIds: [String] = []
    private static let lock = NSLock()

    struct MessageRecord {
        let id: String?
        let sender: String
        let text: String
        let timestamp: Int64
        let quality: Int

        init(id: String?, sender: String, text: String, timestamp: Int64) {
            self.id = id
            self.sender = sender
            self.text = text
            self.timestamp = timestamp
            self.quality = Self.calculateQuality(id: id, sender: sender)
        }

        private static func calculateQuality(id: String?, sender: String) -> Int {
            var q = 0
            if let id = id, !id.isEmpty, id.lowercased() != "null" {
                q += 10
            }
            if !isGenericTitle(sender) {
                q += 5
            }
            return q
        }
    }

    static func clearRoomHistory(roomId: Int, cancelNotification: Bool) {
        lock.lock()
        let removedRecords = roomMessages[roomId] ?? []
        roomMessages.removeValue(forKey: roomId)

        if !removedRecords.isEmpty {
            if recentMessageIds.isEmpty {
                let stored = UserDefaults.standard.array(forKey: recentMessageIdsKey) as? [String] ?? []
                recentMessageIds = stored
            }
            let idsToDrop = Set(removedRecords.compactMap(\.id).filter { isUsableId($0) })
            if !idsToDrop.isEmpty {
                recentMessageIds.removeAll { idsToDrop.contains($0) }
                UserDefaults.standard.set(recentMessageIds, forKey: recentMessageIdsKey)
            }
        }
        lock.unlock()

        guard cancelNotification else { return }
        removeAllScheduledNotifications(for: roomId)
    }

    private static func removeAllScheduledNotifications(for roomId: Int) {
        let center = UNUserNotificationCenter.current()
        let prefix = deliveredNotificationIdentifierPrefix(roomId: roomId)
        let legacyId = notificationIdentifier(for: roomId)

        center.getDeliveredNotifications { notifications in
            let ids = notifications.map(\.request.identifier).filter { id in
                id.hasPrefix(prefix) || id == legacyId
            }
            if !ids.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { id in
                id.hasPrefix(prefix) || id == legacyId
            }
            if !ids.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
    }

    static func coerceMessageId(from dict: [String: Any], keys: [String] = ["id", "messageId", "message_id"]) -> String? {
        for key in keys {
            guard let value = dict[key] else { continue }
            if let s = value as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, t.lowercased() != "null" { return t }
            } else if let n = value as? NSNumber {
                return n.stringValue
            } else if let i = value as? Int {
                return String(i)
            } else if let i = value as? Int64 {
                return String(i)
            }
        }
        return nil
    }

    static func showRoomNotification(
        title: String,
        body: String,
        roomId: Int,
        messageId: String?,
        timestamp: Int64,
        isSync: Bool = false
    ) {
        if addMessageToHistory(roomId: roomId, messageId: messageId, title: title, body: body, timestamp: timestamp, isSync: isSync) {
            triggerNotificationUpdate(roomId: roomId, title: title)
        }
    }

    @discardableResult
    static func addMessageToHistory(
        roomId: Int,
        messageId: String?,
        title: String,
        body: String,
        timestamp: Int64,
        isSync: Bool
    ) -> Bool {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBody.isEmpty { return false }

        let useTimestamp: Int64
        if timestamp > 0 {
            useTimestamp = timestamp
            lock.lock()
            serverTimeOffset = timestamp - Int64(Date().timeIntervalSince1970 * 1000)
            lock.unlock()
        } else {
            lock.lock()
            useTimestamp = Int64(Date().timeIntervalSince1970 * 1000) + serverTimeOffset
            lock.unlock()
        }

        var senderName = title
        if let idx = title.range(of: " in ") {
            senderName = String(title[..<idx.lowerBound])
        }

        lock.lock()
        var history = roomMessages[roomId] ?? []
        if isGenericTitle(senderName) {
            if let previousSender = history.reversed().first(where: { !isGenericTitle($0.sender) })?.sender {
                senderName = previousSender
            }
        }
        if senderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenericTitle(senderName) {
            senderName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? "Messenger"
        }

        let hasId = isUsableId(messageId)
        if hasId, let messageId {
            loadRecentIdsIfNeeded()
            if recentMessageIds.contains(messageId) {
                lock.unlock()
                return false
            }
        }

        let newRecord = MessageRecord(id: messageId, sender: senderName, text: body, timestamp: useTimestamp)
        let normalizedText = trimmedBody.lowercased()

        for index in history.indices {
            let existing = history[index]

            if hasId, messageId == existing.id {
                if newRecord.quality > existing.quality {
                    history.remove(at: index)
                    break
                }
                roomMessages[roomId] = history
                lock.unlock()
                return false
            }

            if hasId, isUsableId(existing.id), messageId != existing.id {
                continue
            }

            let sameText = normalizedText == existing.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let sameSender = senderName == existing.sender
            let withinWindow = abs(useTimestamp - existing.timestamp) < 300_000

            if sameText, sameSender, withinWindow {
                let shouldReplace = (hasId && !isUsableId(existing.id)) || (newRecord.quality > existing.quality)
                if shouldReplace {
                    history.remove(at: index)
                    break
                }
                roomMessages[roomId] = history
                lock.unlock()
                return false
            }
        }

        if hasId, let messageId {
            addAndPersistMessageId(messageId)
        }

        history.append(newRecord)
        history.sort { $0.timestamp < $1.timestamp }
        if history.count > maxMessagesPerRoom {
            history.removeFirst(history.count - maxMessagesPerRoom)
        }
        roomMessages[roomId] = history
        lock.unlock()
        return true
    }

    static func triggerNotificationUpdate(roomId: Int, title: String) {
        let center = UNUserNotificationCenter.current()

        lock.lock()
        let history = roomMessages[roomId] ?? []
        lock.unlock()

        guard let last = history.last else { return }

        let notificationId = deliveredNotificationRequestIdentifier(
            roomId: roomId,
            messageId: last.id,
            timestamp: last.timestamp
        )

        let content = UNMutableNotificationContent()
        content.sound = .default
        content.threadIdentifier = roomId > 0 ? "\(groupKey).room.\(roomId)" : groupKey
        content.categoryIdentifier = channelId
        let lastMessageId = last.id
        if roomId > 0 {
            var info: [String: Any] = ["roomId": roomId]
            if let lastMessageId { info["messageId"] = lastMessageId }
            content.userInfo = info
        } else {
            content.userInfo = [:]
        }

        let conversationTitle: String = {
            if let idx = title.range(of: " in ") {
                let suffix = String(title[idx.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return isGenericTitle(suffix) || suffix.isEmpty ? "Chat" : suffix
            }
            return isGenericTitle(title) ? "Chat" : title
        }()

        content.title = nonEmptyOrDefault(last.sender, fallback: "New Message")
        content.body = last.text
        content.subtitle = conversationTitle
        content.summaryArgument = conversationTitle
        if #available(iOS 12.0, *) {
            content.summaryArgumentCount = 1
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: notificationId, content: content, trigger: trigger)
        center.add(request, withCompletionHandler: nil)
    }

    private static func deliveredNotificationIdentifierPrefix(roomId: Int) -> String {
        if roomId > 0 {
            return "chat.delivered.r\(roomId)."
        }
        return "chat.delivered.gen."
    }

    private static func deliveredNotificationRequestIdentifier(roomId: Int, messageId: String?, timestamp: Int64) -> String {
        let prefix = deliveredNotificationIdentifierPrefix(roomId: roomId)
        if isUsableId(messageId) {
            let safe = sanitizedForNotificationIdentifier(messageId!)
            return "\(prefix)m.\(safe)"
        }
        return "\(prefix)ts.\(timestamp).\(UUID().uuidString.prefix(8))"
    }

    private static func sanitizedForNotificationIdentifier(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("_") })
    }

    private static func notificationIdentifier(for roomId: Int) -> String {
        if roomId > 0 {
            return "chat.room.\(roomId)"
        }
        return "chat.room.\(genericNotificationId)"
    }

    private static func loadRecentIdsIfNeeded() {
        if !recentMessageIds.isEmpty { return }
        let stored = UserDefaults.standard.array(forKey: recentMessageIdsKey) as? [String] ?? []
        recentMessageIds = stored
    }

    private static func addAndPersistMessageId(_ messageId: String) {
        recentMessageIds.removeAll { $0 == messageId }
        recentMessageIds.append(messageId)
        if recentMessageIds.count > maxPersistentIds {
            recentMessageIds.removeFirst(recentMessageIds.count - maxPersistentIds)
        }
        UserDefaults.standard.set(recentMessageIds, forKey: recentMessageIdsKey)
    }

    private static func isGenericTitle(_ title: String?) -> Bool {
        guard let title else { return true }
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized == "new message" || normalized == "new messages" || normalized == "message"
    }

    private static func isUsableId(_ value: String?) -> Bool {
        guard let value else { return false }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty && normalized.lowercased() != "null"
    }

    private static func nonEmptyOrDefault(_ value: String?, fallback: String) -> String {
        guard let value else { return fallback }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? fallback : normalized
    }
}
