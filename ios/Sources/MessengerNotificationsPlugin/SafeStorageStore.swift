//
//  SafeStorageStore.swift
//  App
//
//  Created by Macbook Pro on 08/04/2026.
//
import Foundation

public enum SafeStorageStore {
    /// Set `MessengerNotificationsAppGroup` in the host app's Info.plist (e.g. `group.com.example.app.onesignal`). If unset, only `UserDefaults.standard` is used.
    public static var appGroupSuiteName: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "MessengerNotificationsAppGroup") as? String
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static let rootKey = "safe_storage"
    private static let migrationFlagKey = "safe_storage_app_group_migrated"

    private static var sharedDefaults: UserDefaults? {
        let suite = appGroupSuiteName
        guard !suite.isEmpty else { return nil }
        return UserDefaults(suiteName: suite)
    }

    private static var legacyDefaults: UserDefaults {
        UserDefaults.standard
    }

    private static func dictionary(from defaults: UserDefaults?) -> [String: String] {
        guard let dict = defaults?.dictionary(forKey: rootKey) as? [String: String] else {
            return [:]
        }
        return dict
    }

    private static func synchronizeSharedStoreIfNeeded() {
        guard let sharedDefaults else {
            return
        }

        if sharedDefaults.bool(forKey: migrationFlagKey) {
            return
        }

        let legacyDict = dictionary(from: legacyDefaults)
        let sharedDict = dictionary(from: sharedDefaults)

        if !sharedDict.isEmpty {
            sharedDefaults.set(true, forKey: migrationFlagKey)
            return
        }

        if !legacyDict.isEmpty {
            sharedDefaults.set(legacyDict, forKey: rootKey)
            sharedDefaults.set(true, forKey: migrationFlagKey)
        }
    }

    public static func getAll() -> [String: String] {
        synchronizeSharedStoreIfNeeded()

        let sharedDict = dictionary(from: sharedDefaults)
        if !sharedDict.isEmpty {
            return sharedDict
        }

        return dictionary(from: legacyDefaults)
    }

    public static func get(_ key: String) -> String? {
        return getAll()[key]
    }

    public static func set(_ key: String, value: String?) {
        synchronizeSharedStoreIfNeeded()

        var dict = getAll()
        dict[key] = value
        sharedDefaults?.set(dict, forKey: rootKey)
        legacyDefaults.set(dict, forKey: rootKey)
    }

    public static func remove(_ key: String) {
        synchronizeSharedStoreIfNeeded()

        var dict = getAll()
        dict.removeValue(forKey: key)
        sharedDefaults?.set(dict, forKey: rootKey)
        legacyDefaults.set(dict, forKey: rootKey)
    }
}

enum MessageFlowLogger {
    private static let defaultBaseUrl = "https://4.rw"
    private static let baseUrlKeys = [
        "backendBaseUrl",
        "backend_url",
        "apiBaseUrl",
        "api_base_url",
        "serverUrl",
        "server_url"
    ]

    private static func resolveBaseUrl() -> String {
        for key in baseUrlKeys {
            if let v = SafeStorageStore.get(key), !v.isEmpty {
                return v
            }
        }
        return defaultBaseUrl
    }

    private static func resolveUserId() -> Int? {
        if let raw = SafeStorageStore.get("userId"), let id = Int(raw) {
            return id
        }
        return nil
    }

    static func log(
        traceId: String,
        messageId: String? = nil,
        roomId: Int? = nil,
        userId: Int? = nil,
        stepKey: String,
        stepMessage: String,
        channel: String,
        status: String = "info",
        payload: [String: Any]? = nil,
        error: String? = nil
    ) {
        let normalizedBase = resolveBaseUrl().trimmingCharacters(in: .whitespacesAndNewlines)
        let base = normalizedBase.hasSuffix("/") ? String(normalizedBase.dropLast()) : normalizedBase
        guard let url = URL(string: "\(base)/api/message-flow-logs/ingest") else { return }

        var body: [String: Any] = [
            "trace_id": traceId,
            "step_key": stepKey,
            "step_message": stepMessage,
            "platform": "ios",
            "source": "mobile-native",
            "channel": channel,
            "status": status,
            "created_at": ISO8601DateFormatter().string(from: Date())
        ]

        if let mid = messageId, !mid.isEmpty {
            body["message_id"] = Int(mid) ?? NSNull()
        }
        if let rid = roomId, rid > 0 {
            body["room_id"] = rid
        }
        if let uid = userId ?? resolveUserId() {
            body["user_id"] = uid
        }
        if let payload = payload {
            body["payload"] = payload
        }
        if let error = error {
            body["error"] = error
        }

        guard let data = try? JSONSerialization.data(withJSONObject: body, options: []) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        URLSession.shared.dataTask(with: req).resume()
    }
}


struct SharedNotificationBatchMessage: Codable {
    let messageId: String?
    let roomId: Int
    let title: String
    let body: String
    let timestamp: Int64
    let source: String
}

struct SharedNotificationBatch: Codable {
    let traceId: String
    let roomId: Int?
    let storedAtMs: Int64
    let displayedMessageId: String?
    let messages: [SharedNotificationBatchMessage]
}

enum SharedNotificationState {
    private static let batchKey = "notification_extension.latest_batch"
    private static let shownIdsKey = "notification_extension.shown_message_ids"
    private static let maxShownIds = 500

    private static var sharedDefaults: UserDefaults? {
        let suite = SafeStorageStore.appGroupSuiteName
        guard !suite.isEmpty else { return nil }
        return UserDefaults(suiteName: suite)
    }

    private static func normalizeMessageId(_ messageId: String?) -> String? {
        guard let messageId else { return nil }
        let normalized = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized.lowercased() == "null" {
            return nil
        }
        return normalized
    }

    static func saveExtensionBatch(traceId: String, roomId: Int?, displayedMessageId: String?, messages: [SharedNotificationBatchMessage]) {
        guard let sharedDefaults else { return }
        let batch = SharedNotificationBatch(
            traceId: traceId,
            roomId: roomId,
            storedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            displayedMessageId: normalizeMessageId(displayedMessageId),
            messages: messages
        )
        guard let data = try? JSONEncoder().encode(batch) else { return }
        sharedDefaults.set(data, forKey: batchKey)
    }

    static func loadExtensionBatch() -> SharedNotificationBatch? {
        guard let data = sharedDefaults?.data(forKey: batchKey) else { return nil }
        return try? JSONDecoder().decode(SharedNotificationBatch.self, from: data)
    }

    static func clearExtensionBatch() {
        sharedDefaults?.removeObject(forKey: batchKey)
    }

    static func shownMessageIds() -> [String] {
        sharedDefaults?.array(forKey: shownIdsKey) as? [String] ?? []
    }

    static func wasMessageShown(_ messageId: String?) -> Bool {
        guard let normalized = normalizeMessageId(messageId) else { return false }
        return shownMessageIds().contains(normalized)
    }

    static func markMessageShown(_ messageId: String?) {
        guard let sharedDefaults, let normalized = normalizeMessageId(messageId) else { return }
        var ids = shownMessageIds()
        ids.removeAll { $0 == normalized }
        ids.append(normalized)
        if ids.count > maxShownIds {
            ids.removeFirst(ids.count - maxShownIds)
        }
        sharedDefaults.set(ids, forKey: shownIdsKey)
    }
}
