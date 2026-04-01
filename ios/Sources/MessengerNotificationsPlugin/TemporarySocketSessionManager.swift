import Foundation
import SocketIO
import os.log

public enum TemporarySocketSessionManager {
    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.codecraft_studio.messenger.notifications",
                                   category: "Notifications")
    private static let defaultIdleTimeout: TimeInterval = 15
    private static let defaultConnectTimeout: TimeInterval = 20
    private static let defaultMaxSession: TimeInterval = 45
    private static let defaultSocketURL = "wss://4.rw"

    private static let messageEvents: Set<String> = [
        "sync_messages_response",
        "sync:messages",
        "room:message_notification"
    ]

    public static func runSession(payloadData: [String: Any]?, completion: @escaping (Bool) -> Void) {
        let payloadDescription = String(describing: payloadData ?? [:])
        print("🔌 [TempSocketSession] runSession() payloadData=\(payloadDescription)")
        os_log("🔌 [TempSocketSession] runSession payload=%{public}@",
               log: log,
               type: .info,
               payloadDescription)

        guard let config = resolveConfig(payloadData: payloadData) else {
            print("🔌 [TempSocketSession] Missing socket URL or token, skipping.")
            os_log("🔌 [TempSocketSession] Missing socket URL or token, skipping.",
                   log: log,
                   type: .error)
            completion(false)
            return
        }

        guard let url = URL(string: config.socketUrl) else {
            print("🔌 [TempSocketSession] Invalid socket URL \(config.socketUrl)")
            os_log("🔌 [TempSocketSession] Invalid socket URL %{public}@",
                   log: log,
                   type: .error,
                   config.socketUrl)
            completion(false)
            return
        }

        print("🔌 [TempSocketSession] Using socket URL='\(config.socketUrl)' jwtLength=\(config.jwtToken.count)")
        os_log("🔌 [TempSocketSession] Using socket URL=%{public}@ jwtLength=%{public}d",
               log: log,
               type: .info,
               config.socketUrl,
               config.jwtToken.count)

        let manager = SocketManager(
            socketURL: url,
            config: [
                .forceNew(true),
                .reconnects(false),
                .log(false),
                .connectParams([
                    "token": config.jwtToken,
                    "auth[token]": config.jwtToken
                ]),
                .compress
            ]
        )

        let socket = manager.defaultSocket

        var finished = false
        var messageReceived = false
        var syncResponseReceived = false

        let finish: () -> Void = {
            if finished { return }
            finished = true
            print("🔌 [TempSocketSession] Finishing session. messageReceived=\(messageReceived)")
            os_log("🔌 [TempSocketSession] Finishing session. messageReceived=%{public}@",
                   log: log,
                   type: .info,
                   String(describing: messageReceived))
            socket.removeAllHandlers()
            socket.disconnect()
            completion(messageReceived)
        }

        var idleTimer: Timer?
        func resetIdleTimer() {
            idleTimer?.invalidate()
            idleTimer = Timer.scheduledTimer(withTimeInterval: config.idleTimeout, repeats: false) { _ in
                print("🔌 [TempSocketSession] Idle timeout reached.")
                os_log("🔌 [TempSocketSession] Idle timeout reached after %{public}.1f seconds",
                       log: log,
                       type: .info,
                       config.idleTimeout)
                finish()
            }
        }

        socket.on(clientEvent: .connect) { _, _ in
            print("🔌 [TempSocketSession] Socket connected.")
            os_log("🔌 [TempSocketSession] Socket connected.", log: log, type: .info)
            resetIdleTimer()

            if let payloadData = payloadData {
                var roomIdString: String?
                if let roomId = payloadData["roomId"] as? Int {
                    roomIdString = String(roomId)
                } else if let roomId = payloadData["room_id"] as? Int {
                    roomIdString = String(roomId)
                } else if let roomId = payloadData["roomId"] as? String {
                    roomIdString = roomId
                } else if let roomId = payloadData["room_id"] as? String {
                    roomIdString = roomId
                }

                if let roomId = roomIdString, !roomId.isEmpty {
                    print("🔌 [TempSocketSession] Emitting join_room with roomId=\(roomId)")
                    os_log("🔌 [TempSocketSession] Emitting join_room roomId=%{public}@",
                           log: log,
                           type: .info,
                           roomId)
                    socket.emit("join_room", roomId)
                } else {
                    print("🔌 [TempSocketSession] No roomId in payload for join_room.")
                    os_log("🔌 [TempSocketSession] No roomId in payload for join_room.",
                           log: log,
                           type: .info)
                }
            } else {
                print("🔌 [TempSocketSession] No payloadData provided, skipping join_room.")
                os_log("🔌 [TempSocketSession] No payloadData provided, skipping join_room.",
                       log: log,
                       type: .info)
            }

            print("🔌 [TempSocketSession] Emitting sync_messages.")
            os_log("🔌 [TempSocketSession] Emitting sync_messages.", log: log, type: .info)
            socket.emit("sync_messages") {
                print("🔌 [TempSocketSession] Received sync_messages ACK.")
                os_log("🔌 [TempSocketSession] Received sync_messages ACK.",
                       log: log,
                       type: .info)
                resetIdleTimer()
            }
        }

        socket.onAny { event in
            let name = event.event
            let items = event.items ?? []
            let payloadDescription = String(describing: items)
            print("🔌 [TempSocketSession] Incoming event=\(name) payloadCount=\(items.count) payload=\(payloadDescription)")
            os_log("🔌 [TempSocketSession] Incoming event=%{public}@ payloadCount=%{public}d payload=%{public}@",
                   log: log,
                   type: .debug,
                   name,
                   items.count,
                   payloadDescription)

            if name == "sync_messages_response" {
                syncResponseReceived = true
            }

            if messageEvents.contains(name) {
                if handleSocketArgs(event: name, args: items, syncReceived: syncResponseReceived) {
                    messageReceived = true
                    resetIdleTimer()
                }
            }
        }

        socket.on(clientEvent: .error) { data, _ in
            print("🔌 [TempSocketSession] Socket error: \(data)")
            os_log("🔌 [TempSocketSession] Socket error %{public}@",
                   log: log,
                   type: .error,
                   String(describing: data))
        }

        socket.on(clientEvent: .disconnect) { data, _ in
            print("🔌 [TempSocketSession] Socket disconnected: \(data)")
            os_log("🔌 [TempSocketSession] Socket disconnected %{public}@",
                   log: log,
                   type: .info,
                   String(describing: data))
            finish()
        }

        socket.connect(timeoutAfter: defaultConnectTimeout) {
            print("🔌 [TempSocketSession] Connect timeout reached.")
            os_log("🔌 [TempSocketSession] Connect timeout reached after %{public}.1f seconds",
                   log: log,
                   type: .error,
                   defaultConnectTimeout)
            finish()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + defaultMaxSession) {
            if !finished {
                print("🔌 [TempSocketSession] Max session duration reached.")
                os_log("🔌 [TempSocketSession] Max session duration reached after %{public}.1f seconds",
                       log: log,
                       type: .error,
                       defaultMaxSession)
                finish()
            }
        }
    }

    private struct SessionConfig {
        let jwtToken: String
        let socketUrl: String
        let idleTimeout: TimeInterval
        let maxSession: TimeInterval
        let connectTimeout: TimeInterval

        var isValid: Bool { !jwtToken.isEmpty && !socketUrl.isEmpty }
    }

    private static func resolveConfig(payloadData: [String: Any]?) -> SessionConfig? {
        let jwt = SafeStorageStore.get("token") ?? SafeStorageStore.get("authToken") ?? ""
        let socketFromPayload = payloadData?["socketUrl"] as? String
        let socketFromPrefs = SafeStorageStore.get("socketUrl")
        let base = socketFromPayload ?? socketFromPrefs ?? defaultSocketURL

        if jwt.isEmpty {
            print("🔌 [TempSocketSession] resolveConfig: JWT token is empty, cannot open socket.")
            os_log("🔌 [TempSocketSession] resolveConfig: JWT token is empty, cannot open socket.",
                   log: log,
                   type: .error)
            return nil
        }

        print("🔌 [TempSocketSession] resolveConfig: using base socket URL='\(base)', fromPayload=\(socketFromPayload != nil), fromPrefs=\(socketFromPrefs != nil)")
        os_log("🔌 [TempSocketSession] resolveConfig: base socket URL=%{public}@ fromPayload=%{public}@ fromPrefs=%{public}@",
               log: log,
               type: .info,
               base,
               String(describing: socketFromPayload != nil),
               String(describing: socketFromPrefs != nil))

        let url = normalizeSocketBaseUrl(base)
        return SessionConfig(
            jwtToken: jwt,
            socketUrl: url,
            idleTimeout: defaultIdleTimeout,
            maxSession: defaultMaxSession,
            connectTimeout: defaultConnectTimeout
        )
    }

    private static func normalizeSocketBaseUrl(_ baseUrl: String) -> String {
        var normalized = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasSuffix("/") {
            normalized = String(normalized.dropLast())
        }
        if normalized.hasSuffix("/api") {
            normalized = String(normalized.dropLast(4))
        }
        if !normalized.contains("://") {
            normalized = "https://\(normalized)"
        }
        return normalized
    }

    private static let bulkSyncSocketEvents: Set<String> = ["sync_messages_response", "sync:messages"]

    private static func handleSocketArgs(event: String, args: [Any], syncReceived: Bool) -> Bool {
        print("🔌 [TempSocketSession] handleSocketArgs event=\(event) argsCount=\(args.count)")
        guard !args.isEmpty else { return false }

        let dicts: [[String: Any]] = args.compactMap { arg in
            arg as? [String: Any] ?? (arg as? NSDictionary as? [String: Any])
        }

        if bulkSyncSocketEvents.contains(event) {
            return applyBulkSocketSync(dicts: dicts)
        }

        var handled = false
        for dict in dicts {
            if applySingleSocketRecord(dict, isSync: false) {
                handled = true
            } else if syncReceived, handleUnreadApiRecord(dict) {
                handled = true
            }
        }
        return handled
    }

    private struct NormalizedSocketFields {
        let roomId: Int
        let title: String
        let body: String
        let messageId: String?
        let timestamp: Int64
    }

    private static func normalizedFields(from payload: [String: Any]) -> NormalizedSocketFields? {
        guard let roomId = (payload["room_id"] as? Int) ?? (payload["roomId"] as? Int),
              roomId > 0 else { return nil }

        let senderId = (payload["sender_id"] as? Int) ?? (payload["senderId"] as? Int) ?? 0

        let encryptedMessage = payload["encrypted_message"] as? String
            ?? payload["encryptedMessage"] as? String
            ?? payload["ciphertext"] as? String
        if let enc = encryptedMessage {
            print("🔐 [TempSocketSession] encryptedMessage len=\(enc.count)")
        } else {
            print("🔐 [TempSocketSession] encryptedMessage is nil")
        }

        let encryptedUsername = payload["encrypted_username"] as? String
            ?? payload["encryptedUsername"] as? String
        if let enc = encryptedUsername {
            print("🔐 [TempSocketSession] encryptedUsername len=\(enc.count)")
        }

        let encryptedRoomName = payload["encrypted_room_name"] as? String
            ?? payload["encryptedRoomName"] as? String
        if let enc = encryptedRoomName {
            print("🔐 [TempSocketSession] encryptedRoomName len=\(enc.count)")
        }

        var roomName: String?
        if let encRoom = encryptedRoomName {
            do {
                let result = try NativeCrypto.decryptRoomData(roomId: roomId, encryptedJSON: encRoom)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                print("🔐 [TempSocketSession] roomName decrypted len=\(text.count)")
                if !text.isEmpty {
                    roomName = text
                }
            } catch {
                print("🔐 [TempSocketSession] roomName decrypt error: \(error)")
            }
        }

        var username: String?
        if let encUser = encryptedUsername {
            do {
                let result = try NativeCrypto.decryptUserData(userId: senderId, encryptedJSON: encUser)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                print("🔐 [TempSocketSession] username decrypted len=\(text.count)")
                if !text.isEmpty {
                    username = text
                }
            } catch {
                print("🔐 [TempSocketSession] username decrypt error: \(error)")
            }
        }

        var messageText: String?
        if let encMsg = encryptedMessage {
            do {
                let result = try NativeCrypto.decryptRoomData(roomId: roomId, encryptedJSON: encMsg)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                print("🔐 [TempSocketSession] message decrypted len=\(text.count)")
                if !text.isEmpty {
                    messageText = text
                }
            } catch {
                print("🔐 [TempSocketSession] message decrypt error: \(error)")
            }
        }

        let finalTitle = username ?? roomName ?? "New message"
        let finalBody = messageText ?? "New encrypted message"
        print("🔐 [TempSocketSession] finalTitle='\(finalTitle)' finalBody prefix='\(finalBody.prefix(40))'")

        let messageId = NotificationHelper.coerceMessageId(from: payload)

        let timestampMs: Int64 = {
            if let ts = payload["timestamp"] as? Int64 { return ts }
            if let ts = payload["timestamp"] as? Int { return Int64(ts) }
            if let ts = payload["created_at"] as? Int64 { return ts }
            if let ts = payload["created_at"] as? Int { return Int64(ts) }
            return Int64(Date().timeIntervalSince1970 * 1000)
        }()

        return NormalizedSocketFields(
            roomId: roomId,
            title: finalTitle,
            body: finalBody,
            messageId: messageId,
            timestamp: timestampMs
        )
    }

    private static func applySingleSocketRecord(_ payload: [String: Any], isSync: Bool) -> Bool {
        guard let fields = normalizedFields(from: payload) else { return false }
        NotificationHelper.showRoomNotification(
            title: fields.title,
            body: fields.body,
            roomId: fields.roomId,
            messageId: fields.messageId,
            timestamp: fields.timestamp,
            isSync: isSync
        )
        return true
    }

    private static func applyBulkSocketSync(dicts: [[String: Any]]) -> Bool {
        var byRoom: [Int: [(title: String, body: String, messageId: String?, timestamp: Int64)]] = [:]
        for dict in dicts {
            guard let fields = normalizedFields(from: dict) else { continue }
            byRoom[fields.roomId, default: []].append((fields.title, fields.body, fields.messageId, fields.timestamp))
        }
        if byRoom.isEmpty { return false }
        var handled = false
        for (roomId, rows) in byRoom {
            NotificationHelper.clearRoomHistory(roomId: roomId, cancelNotification: false)
            let sorted = rows.sorted { $0.timestamp < $1.timestamp }
            var lastTitle = "New message"
            var anyAdded = false
            for row in sorted {
                let added = NotificationHelper.addMessageToHistory(
                    roomId: roomId,
                    messageId: row.messageId,
                    title: row.title,
                    body: row.body,
                    timestamp: row.timestamp,
                    isSync: true
                )
                if added {
                    anyAdded = true
                    lastTitle = row.title
                }
            }
            if anyAdded {
                NotificationHelper.triggerNotificationUpdate(roomId: roomId, title: lastTitle)
                handled = true
            }
        }
        return handled
    }

    private static func handleUnreadApiRecord(_ item: [String: Any]) -> Bool {
        print("🔌 [TempSocketSession] handleUnreadApiRecord item=\(item)")
        return true
    }
}
