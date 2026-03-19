import Foundation
import SocketIO
import os.log

public enum TemporarySocketSessionManager {
    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.codecraft_studio.messenger.notifications",
                                   category: "Notifications")
    private static let defaultIdleTimeout: TimeInterval = 15
    private static let defaultConnectTimeout: TimeInterval = 20
    private static let defaultMaxSession: TimeInterval = 45

    private static let messageEvents: Set<String> = [
        "sync_messages_response",
        "sync:messages",
        "room:message_notification"
    ]

    public static func runSession(payloadData: [String: Any]?, completion: @escaping (Bool) -> Void) {
        let jwt = SafeStorageStore.get("auth_token") ?? ""
        let socketFromPayload = payloadData?["socketUrl"] as? String
        let socketFromPrefs = SafeStorageStore.get("socket_url")
        let base = socketFromPayload ?? socketFromPrefs ?? "wss://4.rw"

        if jwt.isEmpty {
            completion(false)
            return
        }

        let url = normalizeSocketBaseUrl(base)
        guard let socketURL = URL(string: url) else {
            completion(false)
            return
        }

        let manager = SocketManager(
            socketURL: socketURL,
            config: [
                .forceNew(true),
                .reconnects(false),
                .log(false),
                .connectParams([
                    "token": jwt,
                    "auth[token]": jwt
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
            socket.removeAllHandlers()
            socket.disconnect()
            completion(messageReceived)
        }

        var idleTimer: Timer?
        func resetIdleTimer() {
            idleTimer?.invalidate()
            idleTimer = Timer.scheduledTimer(withTimeInterval: defaultIdleTimeout, repeats: false) { _ in
                finish()
            }
        }

        socket.on(clientEvent: .connect) { _, _ in
            resetIdleTimer()
            if let payloadData = payloadData {
                let roomId = (payloadData["roomId"] as? Int) ?? (payloadData["room_id"] as? Int) ?? 0
                if roomId > 0 {
                    socket.emit("join_room", String(roomId))
                }
            }
            socket.emit("sync_messages")
        }

        socket.onAny { event in
            let name = event.event
            let items = event.items ?? []

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

        socket.on(clientEvent: .disconnect) { _, _ in
            finish()
        }

        socket.connect(timeoutAfter: defaultConnectTimeout) {
            finish()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + defaultMaxSession) {
            if !finished { finish() }
        }
    }

    private static func normalizeSocketBaseUrl(_ baseUrl: String) -> String {
        var normalized = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasSuffix("/") { normalized = String(normalized.dropLast()) }
        if normalized.hasSuffix("/api") { normalized = String(normalized.dropLast(4)) }
        if !normalized.contains("://") { normalized = "https://\(normalized)" }
        return normalized
    }

    private static func handleSocketArgs(event: String, args: [Any], syncReceived: Bool) -> Bool {
        guard !args.isEmpty else { return false }
        var handled = false
        for arg in args {
            guard let dict = arg as? [String: Any] ?? (arg as? NSDictionary as? [String: Any]) else {
                continue
            }
            if handleNormalizedRecord(dict, isSync: event == "sync_messages_response") {
                handled = true
            }
        }
        return handled
    }

    private static func handleNormalizedRecord(_ payload: [String: Any], isSync: Bool) -> Bool {
        guard let roomId = (payload["room_id"] as? Int) ?? (payload["roomId"] as? Int),
              roomId > 0 else { return false }

        let senderId = (payload["sender_id"] as? Int) ?? (payload["senderId"] as? Int) ?? 0

        let encryptedMessage = payload["encrypted_message"] as? String
            ?? payload["encryptedMessage"] as? String
            ?? payload["ciphertext"] as? String

        let encryptedUsername = payload["encrypted_username"] as? String
            ?? payload["encryptedUsername"] as? String

        let encryptedRoomName = payload["encrypted_room_name"] as? String
            ?? payload["encryptedRoomName"] as? String

        var roomName: String?
        if let encRoom = encryptedRoomName {
            roomName = try? NativeCrypto.decryptRoomData(roomId: roomId, encryptedJSON: encRoom).text
        }

        var username: String?
        if let encUser = encryptedUsername {
            username = try? NativeCrypto.decryptUserData(userId: senderId, encryptedJSON: encUser).text
        }

        var messageText: String?
        if let encMsg = encryptedMessage {
            messageText = try? NativeCrypto.decryptRoomData(roomId: roomId, encryptedJSON: encMsg).text
        }

        let finalTitle = username ?? roomName ?? "New message"
        let finalBody = messageText ?? "New encrypted message"

        let messageId = (payload["id"] as? String)
            ?? (payload["messageId"] as? String)
            ?? (payload["message_id"] as? String)

        let timestampMs: Int64 = {
            if let ts = payload["timestamp"] as? Int64 { return ts }
            if let ts = payload["timestamp"] as? Int { return Int64(ts) }
            return Int64(Date().timeIntervalSince1970 * 1000)
        }()

        NotificationHelper.showRoomNotification(
            title: finalTitle,
            body: finalBody,
            roomId: roomId,
            messageId: messageId,
            timestamp: timestampMs,
            isSync: isSync
        )
        return true
    }
}
