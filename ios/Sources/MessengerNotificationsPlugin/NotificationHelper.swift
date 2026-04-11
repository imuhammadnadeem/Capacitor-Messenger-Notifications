import Foundation
import UserNotifications
import UIKit

public final class NotificationHelper {
    private static let notificationTapDebugTag = "[NotificationTap logic]"
    private static let channelId = "chat_messages"
    private static let groupKey = (Bundle.main.bundleIdentifier ?? "com.messenger.plugin") + ".ROOM_GROUP"
    private static let genericNotificationId = 900_000
    private static let maxPersistentIds = 300
    private static let maxMessagesPerRoom = 50
    private static let notificationGraceMs: Int64 = 10_000
    private static let bridgeDuplicateWindowMs: Int64 = 4_000

    private static let recentMessageIdsKey = "notification_history.recent_message_ids"
    private static var serverTimeOffset: Int64 = 0

    private static var roomMessages: [Int: [MessageRecord]] = [:]
    private static var recentMessageIds: [String] = []
    private static var lastRoomNotificationMs: [Int: Int64] = [:]
    private static var lastAnyNotificationMs: Int64 = 0
    private static var lastBridgeFingerprint: String?
    private static var lastBridgeMessageId: String?
    private static var lastBridgeShownAtMs: Int64 = 0
    private static let lock = NSLock()

    private static var notificationDefaults: UserDefaults {
        UserDefaults(suiteName: SafeStorageStore.appGroupSuiteName) ?? UserDefaults.standard
    }

    private static func normalizeMessageId(_ messageId: String?) -> String? {
        guard let messageId else { return nil }
        let normalized = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized.lowercased() == "null" {
            return nil
        }
        return normalized
    }

    private static func traceIdForNotification(messageId: String?, roomId: Int, timestamp: Int64) -> String {
        if let normalized = normalizeMessageId(messageId) {
            return "msg-\(normalized)"
        }
        return "ios-notification-\(roomId)-\(timestamp)"
    }

    private static func logNotificationStep(
        messageId: String?,
        roomId: Int,
        timestamp: Int64,
        stepKey: String,
        stepMessage: String,
        status: String = "info",
        payload: [String: Any]? = nil,
        error: String? = nil
    ) {
        var enrichedPayload = payload ?? [:]
        enrichedPayload["timestamp_ms"] = Int64(Date().timeIntervalSince1970 * 1000)
        MessageFlowLogger.log(
            traceId: traceIdForNotification(messageId: messageId, roomId: roomId, timestamp: timestamp),
            messageId: normalizeMessageId(messageId),
            roomId: roomId > 0 ? roomId : nil,
            stepKey: stepKey,
            stepMessage: stepMessage,
            channel: "notification",
            status: status,
            payload: enrichedPayload,
            error: error
        )
    }

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

    public static func clearRoomHistory(roomId: Int, cancelNotification: Bool) {
        lock.lock()
        roomMessages.removeValue(forKey: roomId)
        lock.unlock()

        guard cancelNotification else { return }
        removeAllScheduledNotifications(for: roomId)
    }

    public static func clearRoomNotification(roomId: Int) {
        clearRoomHistory(roomId: roomId, cancelNotification: true)
    }

    /// Reconciles room notifications against the latest unread message ids.
    /// Keeps only notifications that map to unread ids and removes stale ones.
    public static func reconcileRoomNotifications(roomId: Int, unreadMessageIds: [String], source: String = "sync_messages") {
        guard roomId > 0 else { return }

        let normalizedUnread = Set(
            unreadMessageIds
                .compactMap { normalizeMessageId($0) }
                .map { sanitizedForNotificationIdentifier($0) }
        )

        lock.lock()
        if var history = roomMessages[roomId] {
            history = history.filter { record in
                guard let id = normalizeMessageId(record.id) else {
                    return false
                }
                return normalizedUnread.contains(sanitizedForNotificationIdentifier(id))
            }
            if history.isEmpty {
                roomMessages.removeValue(forKey: roomId)
            } else {
                roomMessages[roomId] = history
            }
        }
        lock.unlock()

        let center = UNUserNotificationCenter.current()
        let roomPrefix = deliveredNotificationIdentifierPrefix(roomId: roomId)
        let roomThread = "\(groupKey).room.\(roomId)"
        let legacyId = notificationIdentifier(for: roomId)

        func shouldRemove(identifier: String, threadId: String, payload: [String: Any]) -> Bool {
            let isRoomScoped = identifier.hasPrefix(roomPrefix)
                || identifier == legacyId
                || threadId == roomThread
            guard isRoomScoped else { return false }

            if normalizedUnread.isEmpty {
                return true
            }

            if identifier.hasPrefix("\(roomPrefix)m.") {
                let encoded = String(identifier.dropFirst("\(roomPrefix)m.".count))
                return !normalizedUnread.contains(encoded)
            }

            let messageId = coerceMessageId(from: payload)
            guard let messageId = normalizeMessageId(messageId) else {
                return true
            }
            return !normalizedUnread.contains(sanitizedForNotificationIdentifier(messageId))
        }

        center.getDeliveredNotifications { notifications in
            let idsToRemove = notifications.compactMap { notification -> String? in
                let payload = compactStringKeyedDictionary(notification.request.content.userInfo)
                return shouldRemove(
                    identifier: notification.request.identifier,
                    threadId: notification.request.content.threadIdentifier,
                    payload: payload
                ) ? notification.request.identifier : nil
            }

            if !idsToRemove.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: idsToRemove)
            }
        }

        center.getPendingNotificationRequests { requests in
            let idsToRemove = requests.compactMap { request -> String? in
                let payload = compactStringKeyedDictionary(request.content.userInfo)
                return shouldRemove(
                    identifier: request.identifier,
                    threadId: request.content.threadIdentifier,
                    payload: payload
                ) ? request.identifier : nil
            }

            if !idsToRemove.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: idsToRemove)
            }
        }

        logNotificationStep(
            messageId: nil,
            roomId: roomId,
            timestamp: currentTimestampMs(),
            stepKey: "ios_notification_reconciled_with_unread",
            stepMessage: "iOS reconciled room notifications using unread message ids from \(source).",
            status: "success",
            payload: [
                "unread_count": normalizedUnread.count,
                "source": source
            ]
        )
    }

    public static func wasNotificationShownRecently(roomId: Int) -> Bool {
        lock.lock()
        let lastShown = lastRoomNotificationMs[roomId]
        lock.unlock()
        guard let lastShown else { return false }
        return currentTimestampMs() - lastShown < notificationGraceMs
    }

    public static func wasAnyNotificationShownRecently(windowMs: Int64) -> Bool {
        lock.lock()
        let lastShown = lastAnyNotificationMs
        lock.unlock()
        guard lastShown > 0 else { return false }
        return currentTimestampMs() - lastShown < max(0, windowMs)
    }

    public static func shouldSuppressDuplicateBridgeNotification(title: String, body: String, roomId: Int, messageId: String?) -> Bool {
        let normalizedMessageId = normalizeMessageId(messageId)
        let now = currentTimestampMs()

        lock.lock()
        defer { lock.unlock() }

        if normalizedMessageId == nil {
            return true
        }

        if let normalizedMessageId {
            if normalizedMessageId == lastBridgeMessageId && now - lastBridgeShownAtMs < bridgeDuplicateWindowMs {
                return true
            }
            lastBridgeMessageId = normalizedMessageId
            lastBridgeShownAtMs = now
            return false
        }

        if roomId > 0, let lastShown = lastRoomNotificationMs[roomId], now - lastShown < notificationGraceMs {
            return true
        }

        if roomId <= 0, lastAnyNotificationMs > 0, now - lastAnyNotificationMs < bridgeDuplicateWindowMs {
            return true
        }

        let fingerprint = "\(roomId)|\(title.trimmingCharacters(in: .whitespacesAndNewlines))|\(body.trimmingCharacters(in: .whitespacesAndNewlines))"
        if fingerprint == lastBridgeFingerprint, now - lastBridgeShownAtMs < bridgeDuplicateWindowMs {
            return true
        }

        lastBridgeFingerprint = fingerprint
        lastBridgeMessageId = nil
        lastBridgeShownAtMs = now
        return false
    }

    /// Removes every delivered + pending notification tagged for this room (multiple UN ids per room for stacking).
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

    /// Normalizes server ids (JSON often uses numeric `id`).
    public static func coerceMessageId(from dict: [String: Any], keys: [String] = ["id", "messageId", "message_id"]) -> String? {
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

    @discardableResult
    public static func showRoomNotification(
        title: String,
        body: String,
        roomId: Int,
        messageId: String?,
        timestamp: Int64,
        isSync: Bool = false
    ) -> Bool {
        let normalizedMessageId = normalizeMessageId(messageId)
        logNotificationStep(
            messageId: normalizedMessageId,
            roomId: roomId,
            timestamp: timestamp,
            stepKey: "ios_notification_received",
            stepMessage: "iOS notification pipeline received message candidate",
            status: "start",
            payload: [
                "is_sync": isSync,
                "title_preview": String(title.prefix(80)),
                "body_preview": String(body.prefix(120))
            ]
        )

        if shouldSuppressNotificationForRoom(roomId: roomId) {
            logNotificationStep(
                messageId: normalizedMessageId,
                roomId: roomId,
                timestamp: timestamp,
                stepKey: "ios_notification_suppressed_for_room_state",
                stepMessage: "iOS skipped notification because room notifications are muted or the room is currently active in foreground.",
                status: "info"
            )
            return false
        }

        if addMessageToHistory(roomId: roomId, messageId: normalizedMessageId, title: title, body: body, timestamp: timestamp, isSync: isSync) {
            markNotificationShown(roomId: roomId)
            logNotificationStep(
                messageId: normalizedMessageId,
                roomId: roomId,
                timestamp: timestamp,
                stepKey: "ios_notification_history_added",
                stepMessage: "iOS added notification message to in-memory history",
                status: "success"
            )
            triggerNotificationUpdate(roomId: roomId, title: title)
            return true
        } else {
            logNotificationStep(
                messageId: normalizedMessageId,
                roomId: roomId,
                timestamp: timestamp,
                stepKey: "ios_notification_deduped",
                stepMessage: "iOS skipped notification because message was duplicate or lower quality",
                status: "info"
            )
            return false
        }
    }

    @discardableResult
    public static func addMessageToHistory(
        roomId: Int,
        messageId: String?,
        title: String,
        body: String,
        timestamp: Int64,
        isSync: Bool
    ) -> Bool {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBody.isEmpty {
            logNotificationStep(
                messageId: messageId,
                roomId: roomId,
                timestamp: timestamp,
                stepKey: "ios_notification_skipped_empty_body",
                stepMessage: "iOS skipped notification because body text was empty",
                status: "warning"
            )
            return false
        }

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
            if SharedNotificationState.wasMessageShown(messageId) {
                logNotificationStep(
                    messageId: messageId,
                    roomId: roomId,
                    timestamp: useTimestamp,
                    stepKey: "ios_notification_deduped_by_shared_state",
                    stepMessage: "iOS skipped notification because shared app-group state shows this message was already surfaced by another process.",
                    status: "info"
                )
                lock.unlock()
                return false
            }

            loadRecentIdsIfNeeded()
            if recentMessageIds.contains(messageId) {
                logNotificationStep(
                    messageId: messageId,
                    roomId: roomId,
                    timestamp: useTimestamp,
                    stepKey: "ios_notification_deduped_by_recent_id",
                    stepMessage: "iOS skipped notification because message id already exists in recent ids",
                    status: "info"
                )
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
                    logNotificationStep(
                        messageId: messageId,
                        roomId: roomId,
                        timestamp: useTimestamp,
                        stepKey: "ios_notification_history_replaced",
                        stepMessage: "iOS replaced existing history entry with higher quality metadata",
                        status: "success"
                    )
                    break
                }
                logNotificationStep(
                    messageId: messageId,
                    roomId: roomId,
                    timestamp: useTimestamp,
                    stepKey: "ios_notification_deduped_by_message_id",
                    stepMessage: "iOS skipped notification because same message id already exists in room history",
                    status: "info"
                )
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
                    logNotificationStep(
                        messageId: messageId,
                        roomId: roomId,
                        timestamp: useTimestamp,
                        stepKey: "ios_notification_history_replaced_text_match",
                        stepMessage: "iOS replaced older near-duplicate history entry with improved record",
                        status: "success"
                    )
                    break
                }
                logNotificationStep(
                    messageId: messageId,
                    roomId: roomId,
                    timestamp: useTimestamp,
                    stepKey: "ios_notification_deduped_by_text_window",
                    stepMessage: "iOS skipped notification due to same sender/text within dedupe time window",
                    status: "info"
                )
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

        logNotificationStep(
            messageId: messageId,
            roomId: roomId,
            timestamp: useTimestamp,
            stepKey: "ios_notification_history_committed",
            stepMessage: "iOS committed message into notification history",
            status: "success",
            payload: [
                "history_size": history.count,
                "is_sync": isSync
            ]
        )
        return true
    }

    public static func triggerNotificationUpdate(roomId: Int, title: String) {
        let center = UNUserNotificationCenter.current()

        lock.lock()
        let history = roomMessages[roomId] ?? []
        lock.unlock()

        guard let last = history.last else { return }

        logNotificationStep(
            messageId: last.id,
            roomId: roomId,
            timestamp: last.timestamp,
            stepKey: "ios_notification_schedule_started",
            stepMessage: "iOS started scheduling local notification request",
            status: "start",
            payload: [
                "title_preview": String(title.prefix(80)),
                "body_preview": String(last.text.prefix(120))
            ]
        )

        // Unique id per message so new banners stack; same message id reuses one slot (dedupe).
        let notificationId = deliveredNotificationRequestIdentifier(
            roomId: roomId,
            messageId: last.id,
            timestamp: last.timestamp
        )

        let content = UNMutableNotificationContent()
        content.sound = .default
        if #available(iOS 15.0, *) {
     content.relevanceScore = 1.0
}
        // Same thread per room → Notification Center stacks them like a conversation group.
        content.threadIdentifier = roomId > 0 ? "\(groupKey).room.\(roomId)" : groupKey
        content.categoryIdentifier = channelId
        let lastMessageId = last.id
        if roomId > 0 {
            var info: [String: Any] = [
                "roomId": roomId,
                "room_id": roomId,
                "notification_source": "notification_helper_local"
            ]
            if let lastMessageId { info["messageId"] = lastMessageId }
            content.userInfo = info
        } else {
            content.userInfo = ["notification_source": "notification_helper_local"]
        }

        let conversationTitle: String = {
            if let idx = title.range(of: " in ") {
                let suffix = String(title[idx.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return isGenericTitle(suffix) || suffix.isEmpty ? "Chat" : suffix
            }
            return isGenericTitle(title) ? "Chat" : title
        }()

        content.title = nonEmptyOrDefault(conversationTitle, fallback: "Chat")
        content.body = last.text
        content.subtitle = nonEmptyOrDefault(last.sender, fallback: "New Message")
        content.summaryArgument = conversationTitle
        if #available(iOS 12.0, *) {
            content.summaryArgumentCount = 1
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: notificationId, content: content, trigger: trigger)
        print("🔔 [NotificationHelper] [NotificationTap logic] scheduling local notification id=\(notificationId) roomId=\(roomId) messageId=\(lastMessageId ?? "nil") userInfo=\(content.userInfo)")
        center.add(request) { error in
            if let error {
                logNotificationStep(
                    messageId: last.id,
                    roomId: roomId,
                    timestamp: last.timestamp,
                    stepKey: "ios_notification_schedule_failed",
                    stepMessage: "iOS failed to schedule local notification request",
                    status: "error",
                    error: error.localizedDescription
                )
                return
            }

            logNotificationStep(
                messageId: last.id,
                roomId: roomId,
                timestamp: last.timestamp,
                stepKey: "ios_notification_scheduled",
                stepMessage: "iOS scheduled local notification request",
                status: "success",
                payload: [
                    "notification_id": notificationId,
                    "thread_id": content.threadIdentifier
                ]
            )
        }
    }

    /// Prefix for all UN request ids for this room (used to clear every stacked notification).
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
        let stored = notificationDefaults.array(forKey: recentMessageIdsKey) as? [String] ?? []
        recentMessageIds = stored
    }

    private static func addAndPersistMessageId(_ messageId: String) {
        recentMessageIds.removeAll { $0 == messageId }
        recentMessageIds.append(messageId)
        if recentMessageIds.count > maxPersistentIds {
            recentMessageIds.removeFirst(recentMessageIds.count - maxPersistentIds)
        }
        notificationDefaults.set(recentMessageIds, forKey: recentMessageIdsKey)
        SharedNotificationState.markMessageShown(messageId)
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

    private static func currentTimestampMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static func compactStringKeyedDictionary(_ source: [AnyHashable: Any]) -> [String: Any] {
        var mapped: [String: Any] = [:]
        for (key, value) in source {
            mapped[String(describing: key)] = value
        }
        return mapped
    }

    private static func markNotificationShown(roomId: Int) {
        let now = currentTimestampMs()
        lock.lock()
        lastRoomNotificationMs[roomId] = now
        lastAnyNotificationMs = now
        lock.unlock()
    }

    public static func shouldSuppressNotificationInCurrentState(roomId: Int) -> Bool {
        shouldSuppressNotificationForRoom(roomId: roomId)
    }

    private static func shouldSuppressNotificationForRoom(roomId: Int) -> Bool {
        guard roomId > 0 else { return false }

        let mutedRaw = SafeStorageStore.get("room_notification_muted:\(roomId)")
        if mutedRaw == "1" || mutedRaw?.lowercased() == "true" {
            print("🔔 [NotificationHelper] SUPPRESS roomId=\(roomId) reason=muted muted_raw=\(mutedRaw ?? "nil")")
            logNotificationStep(
                messageId: nil, roomId: roomId, timestamp: 0,
                stepKey: "ios_suppress_reason_muted",
                stepMessage: "Notification suppressed because room mute flag is set in SafeStorage.",
                status: "info",
                payload: ["suppress_reason": "muted", "muted_raw": mutedRaw ?? "nil", "notification_room_id": roomId]
            )
            return true
        }

        let legacyEnabledRaw = SafeStorageStore.get("push_notifications_room_\(roomId)")
        if let legacyEnabledRaw, !legacyEnabledRaw.isEmpty, legacyEnabledRaw != "1" {
            print("🔔 [NotificationHelper] SUPPRESS roomId=\(roomId) reason=legacy_push_disabled legacy_key_value=\(legacyEnabledRaw)")
            logNotificationStep(
                messageId: nil, roomId: roomId, timestamp: 0,
                stepKey: "ios_suppress_reason_legacy_disabled",
                stepMessage: "Notification suppressed because legacy push_notifications_room key is not '1' in SafeStorage.",
                status: "info",
                payload: ["suppress_reason": "legacy_push_disabled", "legacy_key_value": legacyEnabledRaw, "notification_room_id": roomId]
            )
            return true
        }

        let activeRoomRaw = SafeStorageStore.get("active_room_id") ?? ""
        let activeRoomId = Int(activeRoomRaw)
        let willSuppress = activeRoomId == roomId

        if willSuppress {
            print("🔔 [NotificationHelper] SUPPRESS roomId=\(roomId) reason=active_room_match active_room_id_raw='\(activeRoomRaw)' active_room_id_parsed=\(activeRoomId as Any)")
            logNotificationStep(
                messageId: nil, roomId: roomId, timestamp: 0,
                stepKey: "ios_suppress_reason_active_room_match",
                stepMessage: "Notification suppressed because active_room_id in SafeStorage matches notification roomId. If this is wrong, the value is stale and was never cleared when leaving the room.",
                status: "info",
                payload: [
                    "suppress_reason": "active_room_match",
                    "active_room_id_raw": activeRoomRaw.isEmpty ? "<empty>" : activeRoomRaw,
                    "active_room_id_parsed": activeRoomId as Any,
                    "notification_room_id": roomId
                ]
            )
        } else {
            print("🔔 [NotificationHelper] NOT suppressed roomId=\(roomId) reason=active_room_no_match active_room_id_raw='\(activeRoomRaw)' active_room_id_parsed=\(activeRoomId as Any)")
            logNotificationStep(
                messageId: nil, roomId: roomId, timestamp: 0,
                stepKey: "ios_suppress_check_active_room_no_match",
                stepMessage: "Notification not suppressed: active_room_id in SafeStorage does not match notification roomId.",
                status: "info",
                payload: [
                    "suppress_reason": "none_room_not_active",
                    "active_room_id_raw": activeRoomRaw.isEmpty ? "<empty>" : activeRoomRaw,
                    "active_room_id_parsed": activeRoomId as Any,
                    "notification_room_id": roomId
                ]
            )
        }

        return willSuppress
    }
}
