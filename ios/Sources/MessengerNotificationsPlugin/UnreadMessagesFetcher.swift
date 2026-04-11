import Foundation
import os.log

public enum UnreadMessagesFetcher {
    private static let connectTimeout: TimeInterval = 8
    private static let readTimeout: TimeInterval = 12
    private static let defaultBaseUrl = "https://4.rw"
    private static let baseUrlKeys: [String] = [
        "backendBaseUrl",
        "backend_url",
        "apiBaseUrl",
        "api_base_url",
        "serverUrl",
        "server_url"
    ]

    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.codecraft_studio.messenger.notifications",
                                   category: "Notifications")

    private static func currentTimestampMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static func logDetailedFlow(
        traceId: String,
        messageId: String? = nil,
        roomId: Int? = nil,
        userId: Int? = nil,
        stepKey: String,
        stepMessage: String,
        channel: String,
        status: String = "info",
        payload: [String: Any] = [:],
        error: String? = nil
    ) {
        var fullPayload = payload
        fullPayload["timestamp_ms"] = currentTimestampMs()
        MessageFlowLogger.log(
            traceId: traceId,
            messageId: messageId,
            roomId: roomId,
            userId: userId,
            stepKey: stepKey,
            stepMessage: stepMessage,
            channel: channel,
            status: status,
            payload: fullPayload,
            error: error
        )
    }

    public static func fetchAndNotify(
        payloadData: [String: Any]?,
        completion: @escaping (Bool) -> Void
    ) {
        let fetchTraceId = "ios-unread-\(currentTimestampMs())"
        guard let token = firstNonEmpty(
            SafeStorageStore.get("token"),
            SafeStorageStore.get("authToken")
        ) else {
            print("🔔 [UnreadMessagesFetcher] No auth token in safe storage.")
            os_log("🔔 [UnreadMessagesFetcher] No auth token in safe storage.",
                   log: log,
                   type: .error)
            logDetailedFlow(
                traceId: fetchTraceId,
                stepKey: "ios_unread_auth_missing",
                stepMessage: "Unread API flow stopped because no auth token was found in secure storage.",
                channel: "api",
                status: "error"
            )
            completion(false)
            return
        }

        guard let unreadUrlString = resolveUnreadUrl(payloadData: payloadData),
              let unreadUrl = URL(string: unreadUrlString) else {
            let payloadDescription = String(describing: payloadData ?? [:])
            print("🔔 [UnreadMessagesFetcher] No unread endpoint configured (payloadData=\(payloadDescription)).")
            os_log("🔔 [UnreadMessagesFetcher] No unread endpoint configured payload=%{public}@",
                   log: log,
                   type: .error,
                   payloadDescription)
            logDetailedFlow(
                traceId: fetchTraceId,
                stepKey: "ios_unread_url_missing",
                stepMessage: "Unread API flow stopped because no valid unread endpoint URL could be resolved from payload or saved config.",
                channel: "api",
                status: "error",
                payload: ["payload_preview": String(payloadDescription.prefix(220))]
            )
            completion(false)
            return
        }

        print("🔔 [UnreadMessagesFetcher] Using unread URL: \(unreadUrlString)")
        os_log("🔔 [UnreadMessagesFetcher] Using unread URL=%{public}@",
               log: log,
               type: .info,
               unreadUrlString)
        MessageFlowLogger.log(
            traceId: fetchTraceId,
            stepKey: "ios_unread_fetch_started",
            stepMessage: "iOS started unread API fetch",
            channel: "api",
            status: "start",
            payload: [
                "url": unreadUrlString,
                "timestamp_ms": currentTimestampMs()
            ]
        )
        logDetailedFlow(
            traceId: fetchTraceId,
            stepKey: "ios_unread_fetch_request_prepared",
            stepMessage: "Unread API request is prepared with Bearer auth and is about to be sent to fetch unread encrypted messages.",
            channel: "api",
            status: "start",
            payload: ["url": unreadUrlString]
        )

        var request = URLRequest(url: unreadUrl, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: connectTimeout + readTimeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let start = Date()
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("🔔 [UnreadMessagesFetcher] Unread API failed with error: \(error.localizedDescription)")
                os_log("🔔 [UnreadMessagesFetcher] Unread API network error=%{public}@",
                       log: log,
                       type: .error,
                       error.localizedDescription)
                logDetailedFlow(
                    traceId: fetchTraceId,
                    stepKey: "ios_unread_network_error",
                    stepMessage: "Unread API request failed due to a network or transport-level error before a successful response was received.",
                    channel: "api",
                    status: "error",
                    error: error.localizedDescription
                )
                completion(false)
                return
            }

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                print("🔔 [UnreadMessagesFetcher] Unread API failed: \(http.statusCode) body=\(body)")
                os_log("🔔 [UnreadMessagesFetcher] Unread API HTTP %ld body=%{public}@",
                       log: log,
                       type: .error,
                       http.statusCode,
                       body)
                logDetailedFlow(
                    traceId: fetchTraceId,
                    stepKey: "ios_unread_http_error",
                    stepMessage: "Unread API returned a non-200 HTTP status, so unread message extraction was aborted.",
                    channel: "api",
                    status: "error",
                    payload: ["http_status": http.statusCode, "body_preview": String(body.prefix(200))]
                )
                completion(false)
                return
            }

            guard let data = data, !data.isEmpty else {
                print("🔔 [UnreadMessagesFetcher] Empty unread response (treated as success).")
                os_log("🔔 [UnreadMessagesFetcher] Empty unread response (treated as success).",
                       log: log,
                       type: .info)
                logDetailedFlow(
                    traceId: fetchTraceId,
                    stepKey: "ios_unread_empty_response",
                    stepMessage: "Unread API returned an empty response and this is treated as a successful no-op with no new notifications.",
                    channel: "api",
                    status: "success"
                )
                completion(true)
                return
            }

            do {
                // Log raw response for debugging (truncate to avoid huge logs)
                let rawBody = String(data: data, encoding: .utf8) ?? ""
                let maxLogChars = 900
                let prefix = rawBody.prefix(maxLogChars)
                let truncated = rawBody.count > maxLogChars
                os_log("🔔 [UnreadMessagesFetcher] Unread API response bytes=%{public}d truncated=%{public}@ bodyPrefix=%{public}@",
                       log: log,
                       type: .info,
                       data.count,
                       String(describing: truncated),
                       String(prefix))

                let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                let messages = json?["messages"] as? [[String: Any]] ?? []
                print("🔔 [UnreadMessagesFetcher] Fetched \(messages.count) unread messages in \(Date().timeIntervalSince(start))s")
                os_log("🔔 [UnreadMessagesFetcher] Fetched %ld unread messages in %{public}.3f seconds",
                       log: log,
                       type: .info,
                       messages.count,
                       Date().timeIntervalSince(start))
                MessageFlowLogger.log(
                    traceId: fetchTraceId,
                    stepKey: "ios_unread_fetch_completed",
                    stepMessage: "iOS unread API fetch completed with \(messages.count) messages",
                    channel: "api",
                    status: "success",
                    payload: [
                        "message_count": messages.count,
                        "timestamp_ms": currentTimestampMs()
                    ]
                )
                logDetailedFlow(
                    traceId: fetchTraceId,
                    stepKey: "ios_unread_records_processing_started",
                    stepMessage: "Unread API returned records and the app is now decrypting each unread message and scheduling local notifications.",
                    channel: "api",
                    status: "start",
                    payload: ["message_count": messages.count]
                )

                for item in messages {
                    notifyFromUnreadRecord(item)
                }

                logDetailedFlow(
                    traceId: fetchTraceId,
                    stepKey: "ios_unread_records_processing_completed",
                    stepMessage: "Unread message processing completed and notification scheduling calls were issued for each valid unread message.",
                    channel: "api",
                    status: "success",
                    payload: ["message_count": messages.count]
                )

                completion(true)
            } catch {
                print("🔔 [UnreadMessagesFetcher] Failed to parse unread response: \(error.localizedDescription)")
                os_log("🔔 [UnreadMessagesFetcher] Failed to parse unread response error=%{public}@",
                       log: log,
                       type: .error,
                       error.localizedDescription)
                logDetailedFlow(
                    traceId: fetchTraceId,
                    stepKey: "ios_unread_parse_error",
                    stepMessage: "Unread API response could not be parsed as expected JSON, so unread notifications could not be produced from this response.",
                    channel: "api",
                    status: "error",
                    error: error.localizedDescription
                )
                completion(false)
            }
        }
        task.resume()
    }

    private static func resolveUnreadUrl(payloadData: [String: Any]?) -> String? {
        if let payloadData = payloadData {
            if let explicit = firstNonEmpty(
                payloadData["unread_url"] as? String,
                payloadData["unreadUrl"] as? String
            ) {
                print("🔔 [UnreadMessagesFetcher] resolveUnreadUrl: using explicit unread URL from payload.")
                os_log("🔔 [UnreadMessagesFetcher] resolveUnreadUrl: using explicit unread URL from payload.",
                       log: log,
                       type: .info)
                return explicit
            }

            if let baseFromPayload = firstNonEmpty(
                payloadData["base_url"] as? String,
                payloadData["baseUrl"] as? String,
                payloadData["backend_url"] as? String,
                payloadData["backendUrl"] as? String,
                payloadData["api_base_url"] as? String,
                payloadData["apiBaseUrl"] as? String
            ) {
                let url = joinUrl(baseFromPayload, path: "/api/rooms/messages/unread")
                print("🔔 [UnreadMessagesFetcher] resolveUnreadUrl: using base URL from payload='\(baseFromPayload)' -> '\(url)'")
                os_log("🔔 [UnreadMessagesFetcher] resolveUnreadUrl: base from payload=%{public}@ -> %{public}@",
                       log: log,
                       type: .info,
                       baseFromPayload,
                       url)
                return url
            }
        }

        for key in baseUrlKeys {
            if let value = SafeStorageStore.get(key), !value.isEmpty {
                let url = joinUrl(value, path: "/api/rooms/messages/unread")
                print("🔔 [UnreadMessagesFetcher] resolveUnreadUrl: using base URL from safe storage key '\(key)'='\(value)' -> '\(url)'")
                os_log("🔔 [UnreadMessagesFetcher] resolveUnreadUrl: base from storage key=%{public}@ value=%{public}@ -> %{public}@",
                       log: log,
                       type: .info,
                       key,
                       value,
                       url)
                return url
            }
        }

        // Final fallback: hard-coded default base URL
        let fallbackUrl = joinUrl(defaultBaseUrl, path: "/api/rooms/messages/unread")
        print("🔔 [UnreadMessagesFetcher] resolveUnreadUrl: using default base URL '\(defaultBaseUrl)' -> '\(fallbackUrl)'")
        os_log("🔔 [UnreadMessagesFetcher] resolveUnreadUrl: using default base URL=%{public}@ -> %{public}@",
               log: log,
               type: .info,
               defaultBaseUrl,
               fallbackUrl)
        return fallbackUrl
    }

    private static func joinUrl(_ baseUrl: String, path: String) -> String {
        let normalizedBase = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        return normalizedBase + normalizedPath
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let v = value, !v.isEmpty {
                return v
            }
        }
        return nil
    }

    private static func looksLikeCiphertextBlob(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        return value.count > 80 && value.range(of: "^[A-Za-z0-9+/=._-]+$", options: .regularExpression) != nil
    }

    @discardableResult
    public static func notifyFromUnreadRecord(_ item: [String: Any]) -> Bool {
        let roomId = (item["roomId"] as? Int)
            ?? (item["room_id"] as? Int)
            ?? (item["roomID"] as? Int)
            ?? 0

        let messageId = NotificationHelper.coerceMessageId(from: item) ?? ""
        let traceId = messageId.isEmpty ? "ios-unread-record-\(currentTimestampMs())" : "msg-\(messageId)"

        let senderId: Int = {
            if let id = item["sender_id"] as? Int { return id }
            if let id = item["senderId"] as? Int { return id }
            if let idStr = item["sender_id"] as? String, let id = Int(idStr) { return id }
            if let idStr = item["senderId"] as? String, let id = Int(idStr) { return id }
            return 0
        }()

        let senderName = (item["sender_name"] as? String)
            ?? (item["senderName"] as? String)
            ?? (item["sender"] as? String)
            ?? ""

        // Unread API may include encrypted username / room name (encrypted JSON strings).
        let encryptedRoomName = (item["encrypted_room_name"] as? String)
            ?? (item["encryptedRoomName"] as? String)
        let encryptedUsername = (item["encrypted_username"] as? String)
            ?? (item["encryptedUsername"] as? String)

        if let enc = encryptedRoomName {
            os_log("🔔 [UnreadMessagesFetcher] unread item encryptedRoomName len=%{public}d",
                   log: log,
                   type: .debug,
                   enc.count)
        }
        if let enc = encryptedUsername {
            os_log("🔔 [UnreadMessagesFetcher] unread item encryptedUsername len=%{public}d senderId=%{public}d",
                   log: log,
                   type: .debug,
                   enc.count,
                   senderId)
        }
        logDetailedFlow(
            traceId: traceId,
            messageId: messageId.isEmpty ? nil : messageId,
            roomId: roomId,
            userId: senderId > 0 ? senderId : nil,
            stepKey: "ios_unread_record_received",
            stepMessage: "A single unread record was received and normalization/decryption has started for title, room name, username, and body text.",
            channel: "notification",
            status: "start",
            payload: ["has_encrypted_room": encryptedRoomName != nil, "has_encrypted_user": encryptedUsername != nil]
        )

        // Decrypt room name + username for kill/background parity with socket notifications.
        let decryptedRoomName: String? = {
            guard roomId > 0 else { return nil }
            guard let enc = encryptedRoomName,
                  enc.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") else { return nil }
            do {
                let result = try NativeCrypto.decryptRoomData(roomId: roomId, encryptedJSON: enc)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                os_log("🔔 [UnreadMessagesFetcher] decryptedRoomName len=%{public}d",
                       log: log,
                       type: .info,
                       text.count)
                return text.isEmpty ? nil : text
            } catch {
                os_log("🔔 [UnreadMessagesFetcher] decryptedRoomName error=%{public}@",
                       log: log,
                       type: .error,
                       String(describing: error))
                return nil
            }
        }()

        let decryptedUsername: String? = {
            guard senderId > 0 else { return nil }
            guard let enc = encryptedUsername,
                  enc.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") else { return nil }
            do {
                let result = try NativeCrypto.decryptUserData(userId: senderId, encryptedJSON: enc)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                os_log("🔔 [UnreadMessagesFetcher] decryptedUsername len=%{public}d",
                       log: log,
                       type: .info,
                       text.count)
                return text.isEmpty ? nil : text
            } catch {
                os_log("🔔 [UnreadMessagesFetcher] decryptedUsername error=%{public}@",
                       log: log,
                       type: .error,
                       String(describing: error))
                return nil
            }
        }()

        // Match iOS formatting used by the JS/socket path: "Sender in RoomName".
        // NotificationHelper parses " in " to set `subtitle` as room name.
        let resolvedSender = decryptedUsername ?? (senderName.isEmpty ? "New message" : senderName)
        let title: String
        if let room = decryptedRoomName, !room.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = "\(resolvedSender) in \(room)"
        } else {
            title = resolvedSender
        }
        os_log("🔔 [UnreadMessagesFetcher] final notification title=%{public}@",
               log: log,
               type: .info,
               title)

        let preview = (item["preview"] as? String)
            ?? (item["body"] as? String)
            ?? (item["message"] as? String)

        let encryptedBlob = (item["encrypted_message"] as? String)
            ?? (item["encryptedMessage"] as? String)
            ?? (item["ciphertext"] as? String)

        let decryptedBody: String? = {
            guard let enc = encryptedBlob,
                  enc.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
                  roomId > 0 else {
                print("🔐 [UnreadMessagesFetcher] No decrypt attempt (missing enc or roomId)")
                return nil
            }
            do {
                let result = try NativeCrypto.decryptRoomData(roomId: roomId, encryptedJSON: enc)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                print("🔐 [UnreadMessagesFetcher] decrypted body len=\(text.count)")
                return text.isEmpty ? nil : text
            } catch {
                print("🔐 [UnreadMessagesFetcher] decrypt error: \(error)")
                return nil
            }
        }()

        let body: String
        if let enc = encryptedBlob {
            print("🔐 [UnreadMessagesFetcher] encryptedBlob len=\(enc.count)")
        }
        if let p = preview {
            print("🔐 [UnreadMessagesFetcher] preview len=\(p.count)")
        }
        if let decrypted = decryptedBody, !decrypted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body = decrypted
        } else if let p = preview,
                  !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !looksLikeCiphertextBlob(p) {
            body = p
        } else if looksLikeCiphertextBlob(encryptedBlob) {
            body = "New encrypted message"
        } else {
            body = "New message"
        }

        let timestampMillis: Int64 = {
            return Int64(Date().timeIntervalSince1970 * 1000)
        }()

        let didShow = NotificationHelper.showRoomNotification(
            title: title,
            body: body,
            roomId: roomId,
            messageId: messageId.isEmpty ? nil : messageId,
            timestamp: timestampMillis,
            isSync: false
        )
        if didShow {
            MessageFlowLogger.log(
                traceId: traceId,
                messageId: messageId.isEmpty ? nil : messageId,
                roomId: roomId,
                userId: senderId > 0 ? senderId : nil,
                stepKey: "ios_notification_from_unread",
                stepMessage: "iOS showed notification from unread sync message",
                channel: "notification",
                status: "success",
                payload: [
                    "title": title,
                    "body_preview": String(body.prefix(120)),
                    "timestamp_ms": currentTimestampMs()
                ]
            )
            logDetailedFlow(
                traceId: traceId,
                messageId: messageId.isEmpty ? nil : messageId,
                roomId: roomId,
                userId: senderId > 0 ? senderId : nil,
                stepKey: "ios_unread_record_notification_scheduled",
                stepMessage: "Unread record processing finished and a detailed local notification request was sent to the notification helper.",
                channel: "notification",
                status: "success",
                payload: ["title": title, "body_preview": String(body.prefix(120))]
            )
        } else {
            logDetailedFlow(
                traceId: traceId,
                messageId: messageId.isEmpty ? nil : messageId,
                roomId: roomId,
                userId: senderId > 0 ? senderId : nil,
                stepKey: "ios_unread_record_notification_suppressed",
                stepMessage: "Unread record was parsed but did not produce a new notification because it was deduped or suppressed by room state.",
                channel: "notification",
                status: "info"
            )
        }
        return didShow
    }
}

