import Foundation

public enum EncryptedMessageNotifier {

    @discardableResult
    public static func notifyFromPushData(_ data: [String: Any]) -> Bool {
        let effective = mergedWithFirstMessage(from: data)

        let roomId = int(from: effective, keys: ["roomId", "room_id"]) ?? 0
        let senderId = int(from: effective, keys: ["senderId", "sender_id", "userId", "user_id"]) ?? 0

        let rawRoomName = firstNonEmptyString(
            from: effective,
            keys: ["encrypted_room_name", "encryptedRoomName", "room_name"]
        )
        let roomName = decryptRoomName(roomId: roomId, encryptedOrPlain: rawRoomName)

        let explicitTitle = firstNonEmptyString(
            from: effective,
            keys: ["title", "notification_title"]
        )
        let explicitBody = firstNonEmptyString(
            from: effective,
            keys: ["body", "message"]
        )

        let messageId = NotificationHelper.coerceMessageId(from: effective)

        let timestampMs = parseTimestamp(
            string: firstNonEmptyString(from: effective, keys: ["created_at", "createdAt", "timestamp"])
        )

        let username = decryptUserName(
            userId: senderId,
            encryptedOrPlain: firstNonEmptyString(
                from: effective,
                keys: ["encrypted_username", "encryptedUsername", "sender_name", "senderName", "username"]
            )
        )

        let message = decryptRoomMessage(
            roomId: roomId,
            encryptedOrPlain: firstNonEmptyString(
                from: effective,
                keys: ["encrypted_message", "encryptedMessage", "body", "message", "ciphertext"]
            )
        )

        var finalBody = message ?? explicitBody
        if isGenericOrEmpty(finalBody) {
            if let rn = roomName, isActuallyDecrypted(rn) {
                finalBody = "New message in \(rn)"
            }
        }

        guard let nonEmptyBody = finalBody?.trimmingCharacters(in: .whitespacesAndNewlines),
              !nonEmptyBody.isEmpty else {
            print("🔐 [EncryptedMessageNotifier] Ignoring push fallback: no usable message body")
            return false
        }

        let title: String = {
            if let t = explicitTitle, !shouldIgnoreGenericPushTitle(t) {
                return t
            }
            if let u = username,
               let rn = roomName,
               isActuallyDecrypted(rn) {
                if u.caseInsensitiveCompare(rn) == .orderedSame {
                    return u
                } else {
                    return "\(u) in \(rn)"
                }
            } else if let u = username {
                return u
            } else if let rn = roomName, isActuallyDecrypted(rn) {
                return "New message in \(rn)"
            } else {
                return "New Message"
            }
        }()

        let tsMs: Int64
        if timestampMs > 0 {
            tsMs = timestampMs
        } else {
            tsMs = Int64(Date().timeIntervalSince1970 * 1000)
        }

        NotificationHelper.showRoomNotification(
            title: title,
            body: nonEmptyBody,
            roomId: roomId,
            messageId: messageId,
            timestamp: tsMs,
            isSync: false
        )

        print("🔐 [EncryptedMessageNotifier] Shown notification via FCM payload fallback title='\(title)' body='\(nonEmptyBody)' roomId=\(roomId)")
        return true
    }

    // MARK: - Decryption helpers

    private static func decryptRoomName(roomId: Int, encryptedOrPlain: String?) -> String? {
        guard roomId > 0,
              let value = encryptedOrPlain,
              looksLikeEncryptedJson(value) else {
            return encryptedOrPlain
        }
        do {
            let result = try NativeCrypto.decryptRoomData(roomId: roomId, encryptedJSON: value)
            return result.text
        } catch {
            print("🔐 [EncryptedMessageNotifier] decryptRoomName error: \(error)")
            return encryptedOrPlain
        }
    }

    private static func decryptUserName(userId: Int, encryptedOrPlain: String?) -> String? {
        guard let value = encryptedOrPlain,
              !value.isEmpty else { return nil }

        guard userId > 0,
              looksLikeEncryptedJson(value) else {
            return value
        }

        do {
            let result = try NativeCrypto.decryptUserData(userId: userId, encryptedJSON: value)
            return result.text
        } catch {
            print("🔐 [EncryptedMessageNotifier] decryptUserName error: \(error)")
            return value
        }
    }

    private static func decryptRoomMessage(roomId: Int, encryptedOrPlain: String?) -> String? {
        guard let value = encryptedOrPlain,
              !value.isEmpty else { return nil }

        guard roomId > 0,
              looksLikeEncryptedJson(value) else {
            if looksLikeCiphertextBlob(value) {
                return nil
            }
            return value
        }

        do {
            let result = try NativeCrypto.decryptRoomData(roomId: roomId, encryptedJSON: value)
            return result.text
        } catch {
            print("🔐 [EncryptedMessageNotifier] decryptRoomMessage error: \(error)")
            return nil
        }
    }

    // MARK: - Small utilities

    private static func mergedWithFirstMessage(from root: [String: Any]) -> [String: Any] {
        var result = root

        guard let messagesValue = root["messages"] else {
            return result
        }

        func asDict(_ any: Any) -> [String: Any]? {
            if let dict = any as? [String: Any] { return dict }
            if let dict = any as? [AnyHashable: Any] {
                var mapped: [String: Any] = [:]
                for (k, v) in dict { mapped[String(describing: k)] = v }
                return mapped
            }
            if let json = any as? String {
                let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return obj
                }
                if let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                   let first = list.first {
                    return first
                }
            }
            return nil
        }

        if let list = messagesValue as? [[String: Any]], let first = list.first {
            first.forEach { k, v in result[k] = v }
        } else if let list = messagesValue as? [Any] {
            if let first = list.first, let dict = asDict(first) {
                dict.forEach { k, v in result[k] = v }
            }
        } else if let dict = asDict(messagesValue) {
            dict.forEach { k, v in result[k] = v }
        }

        return result
    }

    private static func int(from dict: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let v = dict[key] as? Int {
                return v
            }
            if let s = dict[key] as? String,
               let v = Int(s) {
                return v
            }
        }
        return nil
    }

    private static func firstNonEmptyString(from dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let s = dict[key] as? String,
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s
            }
        }
        return nil
    }

    private static func parseTimestamp(string: String?) -> Int64 {
        guard let s = string,
              !s.isEmpty else { return 0 }

        if let v = Int64(s) {
            if v > 1_000_000_000_000 {
                return v
            } else {
                return v * 1000
            }
        }
        return 0
    }

    private static func looksLikeEncryptedJson(_ value: String) -> Bool {
        if value.first == "{" && value.contains("ciphertext") {
            return true
        }
        return false
    }

    private static func looksLikeCiphertextBlob(_ value: String) -> Bool {
        if value.count >= 16 && value.range(of: #"^[0-9A-Fa-f]+$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func isGenericOrEmpty(_ value: String?) -> Bool {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !v.isEmpty else { return true }
        let lower = v.lowercased()
        if lower == "message" || lower == "new message" {
            return true
        }
        return false
    }

    private static func shouldIgnoreGenericPushTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty || trimmed == "message" || trimmed == "new message"
    }

    private static func isActuallyDecrypted(_ value: String) -> Bool {
        !looksLikeEncryptedJson(value) && !looksLikeCiphertextBlob(value)
    }
}
