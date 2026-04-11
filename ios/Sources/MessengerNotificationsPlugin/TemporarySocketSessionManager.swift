
import Foundation
import SocketIO
import os.log

public enum TemporarySocketSessionManager {
    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.codecraft_studio.messenger.notifications",
                                   category: "Notifications")
    private static let defaultIdleTimeout: TimeInterval = 30
    private static let defaultConnectTimeout: TimeInterval = 20
    private static let defaultMaxSession: TimeInterval = 45
    private static let defaultConnectAttempts: Int = 1
    private static let defaultReconnectDelay: TimeInterval = 1.2
    private static let defaultEnableQueryAuth: Bool = true
    private static let defaultAllowPollingFallback: Bool = true
    private static let defaultPreferPolling: Bool = false
    private static let defaultSocketURL = "https://4.rw"
    private static var retainedManagers: [String: SocketManager] = [:]
    private static let retainedManagersQueue = DispatchQueue(label: "TemporarySocketSessionManager.retainedManagers")
    private static let socketSessionLockQueue = DispatchQueue(label: "TemporarySocketSessionManager.socketSessionLock")
    private static var socketSessionInUse = false

    private static func retainManager(_ manager: SocketManager, for sessionId: String) {
        retainedManagersQueue.sync {
            retainedManagers[sessionId] = manager
        }
    }

    private static func releaseManager(for sessionId: String) {
        retainedManagersQueue.sync {
            retainedManagers.removeValue(forKey: sessionId)
        }
    }

    @discardableResult
    private static func tryAcquireSocketSessionLock() -> Bool {
        socketSessionLockQueue.sync {
            if socketSessionInUse {
                return false
            }
            socketSessionInUse = true
            return true
        }
    }

    private static func releaseSocketSessionLock() {
        socketSessionLockQueue.sync {
            socketSessionInUse = false
        }
    }

    private static let messageEvents: Set<String> = [
        "sync_messages_response",
        "sync:messages",
        "room:message_notification",
        // "notification:new",
        // "message:new",
        // "new_message",
        // "message"
    ]

    private static func normalizedMessageId(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized.lowercased() == "null" {
            return nil
        }
        return normalized
    }

    private static func traceIdForSocket(messageId: String?, roomId: Int?, fallbackPrefix: String = "ios-socket") -> String {
        if let messageId = normalizedMessageId(messageId) {
            return "msg-\(messageId)"
        }
        if let roomId, roomId > 0 {
            return "\(fallbackPrefix)-room-\(roomId)-\(Int(Date().timeIntervalSince1970 * 1000))"
        }
        return "\(fallbackPrefix)-\(Int(Date().timeIntervalSince1970 * 1000))"
    }

    private static func socketStepLog(
        traceId: String,
        messageId: String? = nil,
        roomId: Int? = nil,
        userId: Int? = nil,
        stepKey: String,
        stepMessage: String,
        status: String = "info",
        payload: [String: Any]? = nil,
        error: String? = nil
    ) {
        var enrichedPayload = payload ?? [:]
        enrichedPayload["timestamp_ms"] = Int64(Date().timeIntervalSince1970 * 1000)
        MessageFlowLogger.log(
            traceId: traceId,
            messageId: normalizedMessageId(messageId),
            roomId: roomId,
            userId: userId,
            stepKey: stepKey,
            stepMessage: stepMessage,
            channel: "socket",
            status: status,
            payload: enrichedPayload,
            error: error
        )
    }

    private static func stringValue(_ payload: [String: Any]?, keys: [String]) -> String? {
        guard let payload else { return nil }
        for key in keys {
            if let value = payload[key] as? String, !value.isEmpty {
                return value
            }
            if let value = payload[key] as? Int {
                return String(value)
            }
            if let value = payload[key] as? Int64 {
                return String(value)
            }
        }
        return nil
    }

    private static func intValue(_ payload: [String: Any]?, keys: [String]) -> Int? {
        guard let payload else { return nil }
        for key in keys {
            if let value = payload[key] as? Int {
                return value
            }
            if let value = payload[key] as? Int64 {
                return Int(value)
            }
            if let value = payload[key] as? String, let parsed = Int(value) {
                return parsed
            }
        }
        return nil
    }

    private static func dictionaryValue(_ payload: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let dict = payload[key] as? [String: Any] {
                return dict
            }
            if let dict = payload[key] as? NSDictionary {
                return dict as? [String: Any]
            }
        }
        return nil
    }

    private static func boolValueAny(_ payload: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = payload[key] as? Bool {
                return value
            }
            if let value = payload[key] as? NSNumber {
                return value.boolValue
            }
            if let value = payload[key] as? String {
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if ["true", "1", "yes", "on"].contains(normalized) { return true }
                if ["false", "0", "no", "off"].contains(normalized) { return false }
            }
        }
        return nil
    }

    private static func isClearNotificationPayload(_ payloadData: [String: Any]?) -> Bool {
        guard let payloadData else { return false }
        var merged = payloadData

        if let data = dictionaryValue(payloadData, keys: ["data"]) {
            merged.merge(data) { _, new in new }
        }
        if let message = dictionaryValue(payloadData, keys: ["message"]) {
            merged.merge(message) { _, new in new }
        }
        if let custom = dictionaryValue(payloadData, keys: ["custom"]),
           let additional = dictionaryValue(custom, keys: ["a"]) {
            merged.merge(additional) { _, new in new }
        }

        let action = stringValue(merged, keys: ["action", "type"])?.lowercased()
        let clearFlag = boolValueAny(merged, keys: ["clear_notification", "clearNotification"]) ?? false
        return action == "clear_notification" || clearFlag
    }

    public static func runSession(payloadData: [String: Any]?, completion: @escaping (Bool) -> Void) {
        let sessionStartMs = Int64(Date().timeIntervalSince1970 * 1000)
        let seedMessageId = stringValue(payloadData, keys: ["message_id", "messageId", "id"])
        let seedRoomId = intValue(payloadData, keys: ["room_id", "roomId"])
        let seedTraceId = seedMessageId.map { "msg-\($0)" } ?? "ios-socket-\(Int(Date().timeIntervalSince1970 * 1000))"
        let clearMode = isClearNotificationPayload(payloadData)
        let sessionId = UUID().uuidString
        let payloadDescription = String(describing: payloadData ?? [:])
        print("🔌 [TempSocketSession] runSession() payloadData=\(payloadDescription)")
        os_log("🔌 [TempSocketSession] runSession payload=%{public}@",
               log: log,
               type: .info,
               payloadDescription)
        socketStepLog(
            traceId: seedTraceId,
            messageId: seedMessageId,
            roomId: seedRoomId,
            stepKey: "ios_socket_session_started",
            stepMessage: "iOS temporary socket session started",
            status: "start",
            payload: [
                "payload_preview": String(payloadDescription.prefix(220)),
                "clear_mode": clearMode
            ]
        )

        guard tryAcquireSocketSessionLock() else {
            print("🔌 [TempSocketSession] Session lock is busy. Skipping duplicate socket connection.")
            os_log("🔌 [TempSocketSession] Session lock is busy. Skipping duplicate socket connection.",
                   log: log,
                   type: .info)
            socketStepLog(
                traceId: seedTraceId,
                messageId: seedMessageId,
                roomId: seedRoomId,
                stepKey: "ios_socket_session_coalesced",
                stepMessage: "Skipped socket connection because another temporary socket session is already active",
                status: "info"
            )
            completion(true)
            return
        }

        guard let config = resolveConfig(payloadData: payloadData) else {
            print("🔌 [TempSocketSession] Missing socket URL or token, skipping.")
            os_log("🔌 [TempSocketSession] Missing socket URL or token, skipping.",
                   log: log,
                   type: .error)
            socketStepLog(
                traceId: seedTraceId,
                messageId: seedMessageId,
                roomId: seedRoomId,
                stepKey: "ios_socket_config_missing",
                stepMessage: "Socket session aborted because URL or token configuration was missing",
                status: "error"
            )
            releaseSocketSessionLock()
            completion(false)
            return
        }

        guard let url = URL(string: config.socketUrl) else {
            print("🔌 [TempSocketSession] Invalid socket URL \(config.socketUrl)")
            os_log("🔌 [TempSocketSession] Invalid socket URL %{public}@",
                   log: log,
                   type: .error,
                   config.socketUrl)
            socketStepLog(
                traceId: seedTraceId,
                messageId: seedMessageId,
                roomId: seedRoomId,
                stepKey: "ios_socket_url_invalid",
                stepMessage: "Socket session aborted because socket URL was invalid",
                status: "error",
                payload: ["socket_url": config.socketUrl]
            )
            releaseSocketSessionLock()
            completion(false)
            return
        }

        print("🔌 [TempSocketSession] Using socket URL='\(config.socketUrl)' jwtLength=\(config.jwtToken.count)")
        os_log("🔌 [TempSocketSession] Using socket URL=%{public}@ jwtLength=%{public}d",
               log: log,
               type: .info,
               config.socketUrl,
               config.jwtToken.count)
        
        socketStepLog(
            traceId: seedTraceId,
            messageId: seedMessageId,
            roomId: seedRoomId,
            stepKey: "ios_socket_connecting",
            stepMessage: "iOS preparing Socket.IO manager and attempting connection",
            status: "start",
            payload: ["socket_url": config.socketUrl]
        )

        var socketOptions: SocketIOClientConfiguration = [
            .forceNew(true),
            .reconnects(false),
            .log(true),
            .version(.three),
            .path(config.socketPath),
            .connectParams([
                "token": config.jwtToken,
                "authToken": config.jwtToken,
                "auth[token]": config.jwtToken,
                "access_token": config.jwtToken,
                "jwt": config.jwtToken
            ]),
            .extraHeaders([
                "Authorization": "Bearer \(config.jwtToken)"
            ]),
            .compress
        ]
        let transportMode: String
        if config.preferPolling {
            socketOptions.insert(.forcePolling(true))
            transportMode = "polling_only"
        } else if !config.allowPollingFallback {
            socketOptions.insert(.forceWebsockets(true))
            transportMode = "websocket_only"
        } else {
            transportMode = "websocket_with_polling_fallback"
        }
        socketStepLog(
            traceId: seedTraceId,
            messageId: seedMessageId,
            roomId: seedRoomId,
            stepKey: "ios_socket_transport_selected",
            stepMessage: "Socket transport strategy selected before session connection attempt.",
            status: "info",
            payload: [
                "transport_mode": transportMode,
                "allow_polling_fallback": config.allowPollingFallback,
                "prefer_polling": config.preferPolling,
                "session_elapsed_ms": Int64(Date().timeIntervalSince1970 * 1000) - sessionStartMs
            ]
        )

        let manager = SocketManager(socketURL: url, config: socketOptions)
        retainManager(manager, for: sessionId)

        let socket = manager.defaultSocket

        var finished = false
        var reconnectScheduled = false
        var connectAttemptsUsed = 0
        var hasConnectedOnce = false
        var messageReceived = false
        var syncResponseReceived = false
        var syncMessagesEmitted = false
        var didHandleConnectedState = false
        var connectAttemptStartedAtMs = sessionStartMs
        var firstSocketEventAtMs: Int64?
        var firstNotificationAtMs: Int64?
        var bufferedDirectEvents: [(name: String, items: [Any], queuedAtMs: Int64)] = []
        var bufferedDirectEventsFlushWorkItem: DispatchWorkItem?

        let finish: () -> Void = {
            if finished { return }
            finished = true
            bufferedDirectEventsFlushWorkItem?.cancel()
            bufferedDirectEventsFlushWorkItem = nil
            let finishMs = Int64(Date().timeIntervalSince1970 * 1000)
            print("🔌 [TempSocketSession] Finishing session. messageReceived=\(messageReceived)")
            os_log("🔌 [TempSocketSession] Finishing session. messageReceived=%{public}@",
                   log: log,
                   type: .info,
                   String(describing: messageReceived))
            socketStepLog(
                traceId: seedTraceId,
                messageId: seedMessageId,
                roomId: seedRoomId,
                stepKey: "ios_socket_session_finished",
                stepMessage: messageReceived ? "Socket session finished after receiving message events" : "Socket session finished without message events",
                status: messageReceived ? "success" : "info",
                payload: [
                    "message_received": messageReceived,
                    "session_duration_ms": finishMs - sessionStartMs,
                    "first_event_elapsed_ms": firstSocketEventAtMs.map { $0 - sessionStartMs } as Any,
                    "first_notification_elapsed_ms": firstNotificationAtMs.map { $0 - sessionStartMs } as Any
                ]
            )
            socket.removeAllHandlers()
            socket.disconnect()
            releaseManager(for: sessionId)
            releaseSocketSessionLock()
            completion(messageReceived)
        }

        func noteNotificationOutput(eventName: String, at nowMs: Int64) {
            if firstNotificationAtMs == nil {
                firstNotificationAtMs = nowMs
                socketStepLog(
                    traceId: seedTraceId,
                    messageId: seedMessageId,
                    roomId: seedRoomId,
                    stepKey: "ios_socket_first_notification_output",
                    stepMessage: "First notification-producing socket payload completed for this session.",
                    status: "success",
                    payload: [
                        "event": eventName,
                        "first_notification_elapsed_ms": nowMs - sessionStartMs,
                        "connect_to_first_notification_ms": nowMs - connectAttemptStartedAtMs
                    ]
                )
            }
            messageReceived = true
            resetIdleTimer()
        }

        func flushBufferedDirectEvents(reason: String, syncReceivedForFlush: Bool) -> Bool {
            bufferedDirectEventsFlushWorkItem?.cancel()
            bufferedDirectEventsFlushWorkItem = nil

            guard !bufferedDirectEvents.isEmpty else { return false }

            let queued = bufferedDirectEvents
            bufferedDirectEvents.removeAll()
            let flushStartedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            var displayed = false

            socketStepLog(
                traceId: seedTraceId,
                messageId: seedMessageId,
                roomId: seedRoomId,
                stepKey: "ios_buffered_direct_events_flushing",
                stepMessage: "Flushing buffered direct room message events after sync gate",
                status: "info",
                payload: [
                    "reason": reason,
                    "buffered_count": queued.count,
                    "sync_received": syncReceivedForFlush
                ]
            )

            for queuedEvent in queued {
                if handleSocketArgs(
                    event: queuedEvent.name,
                    args: queuedEvent.items,
                    syncReceived: syncReceivedForFlush,
                    clearMode: clearMode,
                    traceId: seedTraceId,
                    seedMessageId: seedMessageId,
                    seedRoomId: seedRoomId
                ) {
                    displayed = true
                }
            }

            if displayed {
                noteNotificationOutput(eventName: reason, at: flushStartedAtMs)
            }

            socketStepLog(
                traceId: seedTraceId,
                messageId: seedMessageId,
                roomId: seedRoomId,
                stepKey: "ios_buffered_direct_events_flushed",
                stepMessage: displayed
                    ? "Buffered direct room message events produced notification output after flush"
                    : "Buffered direct room message events were fully deduped or suppressed after flush",
                status: displayed ? "success" : "info",
                payload: [
                    "reason": reason,
                    "buffered_count": queued.count,
                    "sync_received": syncReceivedForFlush,
                    "flush_elapsed_ms": Int64(Date().timeIntervalSince1970 * 1000) - flushStartedAtMs
                ]
            )

            return displayed
        }

        func scheduleBufferedDirectEventFlushIfNeeded() {
            guard bufferedDirectEventsFlushWorkItem == nil else { return }
            let workItem = DispatchWorkItem {
                guard !finished else { return }
                guard !syncResponseReceived else { return }
                _ = flushBufferedDirectEvents(reason: "sync_response_timeout", syncReceivedForFlush: false)
            }
            bufferedDirectEventsFlushWorkItem = workItem
            socketStepLog(
                traceId: seedTraceId,
                messageId: seedMessageId,
                roomId: seedRoomId,
                stepKey: "ios_buffered_direct_events_flush_scheduled",
                stepMessage: "Scheduled fallback flush for direct room events while waiting for sync response",
                status: "info",
                payload: [
                    "delay_ms": 1200,
                    "buffered_count": bufferedDirectEvents.count
                ]
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
        }

        func connectAuthPayload() -> [String: Any] {
            [
                "token": config.jwtToken,
                "authToken": config.jwtToken
            ]
        }

        func scheduleReconnect(reason: String) {
            guard !finished else { return }
            guard !reconnectScheduled else { return }
            guard connectAttemptsUsed < config.maxConnectAttempts else {
                socketStepLog(
                    traceId: seedTraceId,
                    messageId: seedMessageId,
                    roomId: seedRoomId,
                    stepKey: "ios_socket_reconnect_exhausted",
                    stepMessage: "Socket reconnect budget exhausted",
                    status: "error",
                    payload: [
                        "reason": reason,
                        "max_attempts": config.maxConnectAttempts,
                        "attempts_used": connectAttemptsUsed
                    ]
                )
                finish()
                return
            }

            reconnectScheduled = true
            socketStepLog(
                traceId: seedTraceId,
                messageId: seedMessageId,
                roomId: seedRoomId,
                stepKey: "ios_socket_reconnect_scheduled",
                stepMessage: "Socket reconnect scheduled after disconnect/error",
                status: "warning",
                payload: [
                    "reason": reason,
                    "delay_sec": config.reconnectDelay,
                    "attempt_next": connectAttemptsUsed + 1,
                    "max_attempts": config.maxConnectAttempts
                ]
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + config.reconnectDelay) {
                reconnectScheduled = false
                guard !finished else { return }
                connectSocket(reason: "reconnect_\(reason)")
            }
        }

        func connectSocket(reason: String) {
            guard !finished else { return }
            guard connectAttemptsUsed < config.maxConnectAttempts else {
                socketStepLog(
                    traceId: seedTraceId,
                    messageId: seedMessageId,
                    roomId: seedRoomId,
                    stepKey: "ios_socket_connect_attempts_exhausted",
                    stepMessage: "Socket connect attempts exhausted before successful connection",
                    status: "error",
                    payload: [
                        "reason": reason,
                        "max_attempts": config.maxConnectAttempts,
                        "attempts_used": connectAttemptsUsed
                    ]
                )
                finish()
                return
            }

            connectAttemptsUsed += 1
            connectAttemptStartedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            socketStepLog(
                traceId: seedTraceId,
                messageId: seedMessageId,
                roomId: seedRoomId,
                stepKey: "ios_socket_connect_invoked",
                stepMessage: "Socket connect invoked with auth payload",
                status: "start",
                payload: [
                    "reason": reason,
                    "attempt": connectAttemptsUsed,
                    "max_attempts": config.maxConnectAttempts,
                    "connect_timeout_sec": config.connectTimeout,
                    "socket_url": config.socketUrl,
                    "socket_path": config.socketPath,
                    "query_auth_enabled": config.enableQueryAuth,
                    "allow_polling_fallback": config.allowPollingFallback,
                    "prefer_polling": config.preferPolling,
                    "status_before_connect": socket.status.rawValue,
                    "transport_mode": transportMode,
                    "session_elapsed_ms": connectAttemptStartedAtMs - sessionStartMs
                ]
            )

            socket.connect(withPayload: connectAuthPayload(), timeoutAfter: config.connectTimeout) {
                guard !finished else { return }
                if socket.status == .connected {
                    return
                }
                socketStepLog(
                    traceId: seedTraceId,
                    messageId: seedMessageId,
                    roomId: seedRoomId,
                    stepKey: "ios_socket_connect_timeout",
                    stepMessage: "Socket connect attempt timed out",
                    status: "error",
                    payload: [
                        "attempt": connectAttemptsUsed,
                        "max_attempts": config.maxConnectAttempts,
                        "connect_timeout_sec": config.connectTimeout,
                        "attempt_elapsed_ms": Int64(Date().timeIntervalSince1970 * 1000) - connectAttemptStartedAtMs,
                        "session_elapsed_ms": Int64(Date().timeIntervalSince1970 * 1000) - sessionStartMs
                    ]
                )
                scheduleReconnect(reason: "connect_timeout")
            }
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
                socketStepLog(
                    traceId: seedTraceId,
                    messageId: seedMessageId,
                    roomId: seedRoomId,
                    stepKey: "ios_socket_idle_timeout",
                    stepMessage: "Socket session stopped because idle timeout was reached",
                    status: "warning",
                    payload: ["idle_timeout_sec": config.idleTimeout]
                )
                finish()
            }
        }

        func emitSyncMessagesIfNeeded(source: String) {
            let currentStatus = socket.status
            if syncMessagesEmitted {
                socketStepLog(
                    traceId: seedTraceId,
                    messageId: seedMessageId,
                    roomId: seedRoomId,
                    stepKey: "ios_sync_messages_emit_skipped",
                    stepMessage: "Skipped duplicate sync_messages emit request from \(source)",
                    status: "info",
                    payload: [
                        "source": source,
                        "socket_status": currentStatus.rawValue
                    ]
                )
                return
            }

            guard currentStatus == .connected else {
                socketStepLog(
                    traceId: seedTraceId,
                    messageId: seedMessageId,
                    roomId: seedRoomId,
                    stepKey: "ios_sync_messages_emit_blocked",
                    stepMessage: "sync_messages emit blocked because socket is not connected",
                    status: "warning",
                    payload: [
                        "source": source,
                        "socket_status": currentStatus.rawValue
                    ]
                )
                return
            }

            syncMessagesEmitted = true
            print("🔌 [TempSocketSession] Emitting sync_messages. source=\(source) status=\(currentStatus.rawValue)")
            // os_log("🔌 [TempSocketSession] Emitting sync_messages source=%{public}@ status=%{public}@",
            //        log: log,
            //        type: .info,
            //        source,
            //        currentStatus.rawValue)
            MessageFlowLogger.log(
                traceId: seedTraceId,
                messageId: seedMessageId,
                roomId: seedRoomId,
                stepKey: "ios_sync_messages_emitted",
                stepMessage: "iOS emitted sync_messages after background socket connect",
                channel: "socket",
                status: "success",
                payload: [
                    "source": source,
                    "socket_status": currentStatus.rawValue
                ]
            )

            socket.emit("sync_messages") {
                print("🔌 [TempSocketSession] Received sync_messages ACK. source=\(source)")
                os_log("🔌 [TempSocketSession] Received sync_messages ACK. source=%{public}@",
                       log: log,
                       type: .info,
                       source)
                MessageFlowLogger.log(
                    traceId: seedTraceId,
                    messageId: seedMessageId,
                    roomId: seedRoomId,
                    stepKey: "ios_sync_messages_ack_received",
                    stepMessage: "iOS received sync_messages ACK from server",
                    channel: "socket",
                    status: "success",
                    payload: [
                        "source": source
                    ]
                )
                resetIdleTimer()
            }

        }

        func tryEmitSync(retries: Int, delaySeconds: TimeInterval = 0.5) {
            guard retries > 0 else {
                socketStepLog(
                    traceId: seedTraceId,
                    messageId: seedMessageId,
                    roomId: seedRoomId,
                    stepKey: "ios_sync_retry_exhausted",
                    stepMessage: "Sync retry loop exhausted without connected socket state",
                    status: "warning"
                )
                return
            }

            if finished || syncMessagesEmitted {
                return
            }

            let currentStatus = socket.status
            if currentStatus == .connected {
                emitSyncMessagesIfNeeded(source: "retry_loop_\(retries)")
                return
            }

            socketStepLog(
                traceId: seedTraceId,
                messageId: seedMessageId,
                roomId: seedRoomId,
                stepKey: "ios_sync_retry_waiting",
                stepMessage: "Sync retry waiting for connected socket state",
                status: "info",
                payload: [
                    "retries_left": retries,
                    "socket_status": currentStatus.description,
                    "socket_status_raw": currentStatus.rawValue,
                    "delay_sec": delaySeconds
                ]
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) {
                tryEmitSync(retries: retries - 1, delaySeconds: delaySeconds)
            }
        }

        func handleConnectedState(source: String) {
            if didHandleConnectedState {
                socketStepLog(
                    traceId: seedTraceId,
                    messageId: seedMessageId,
                    roomId: seedRoomId,
                    stepKey: "ios_socket_connected_state_duplicate",
                    stepMessage: "Connected-state handler was skipped because it already ran",
                    status: "info",
                    payload: ["source": source]
                )
                return
            }

            didHandleConnectedState = true
            print("🔌 [TempSocketSession] Connected-state handler source=\(source)")
            os_log("🔌 [TempSocketSession] Connected-state handler source=%{public}@", log: log, type: .info, source)

            hasConnectedOnce = true
            MessageFlowLogger.log(
                traceId: seedTraceId,
                messageId: seedMessageId,
                roomId: seedRoomId,
                stepKey: "ios_socket_connected",
                stepMessage: "iOS background socket connected after wake-up",
                channel: "socket",
                status: "success",
                payload: [
                    "source": source,
                    "transport_mode": transportMode,
                    "connect_elapsed_ms": Int64(Date().timeIntervalSince1970 * 1000) - connectAttemptStartedAtMs,
                    "session_elapsed_ms": Int64(Date().timeIntervalSince1970 * 1000) - sessionStartMs
                ]
            )
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
                    socketStepLog(
                        traceId: seedTraceId,
                        messageId: seedMessageId,
                        roomId: Int(roomId),
                        stepKey: "ios_join_room_emitted",
                        stepMessage: "iOS emitted join_room before sync_messages",
                        status: "success",
                        payload: ["room_id": roomId, "source": source]
                    )
                } else {
                    print("🔌 [TempSocketSession] No roomId in payload for join_room.")
                    os_log("🔌 [TempSocketSession] No roomId in payload for join_room.",
                           log: log,
                           type: .info)
                    socketStepLog(
                        traceId: seedTraceId,
                        messageId: seedMessageId,
                        roomId: seedRoomId,
                        stepKey: "ios_join_room_skipped",
                        stepMessage: "iOS skipped join_room because payload had no room id",
                        status: "info",
                        payload: ["source": source]
                    )
                }
            } else {
                print("🔌 [TempSocketSession] No payloadData provided, skipping join_room.")
                os_log("🔌 [TempSocketSession] No payloadData provided, skipping join_room.",
                       log: log,
                       type: .info)
                socketStepLog(
                    traceId: seedTraceId,
                    messageId: seedMessageId,
                    roomId: seedRoomId,
                    stepKey: "ios_join_room_skipped_no_payload",
                    stepMessage: "iOS skipped join_room because no payload data was provided",
                    status: "info",
                    payload: ["source": source]
                )
            }

            emitSyncMessagesIfNeeded(source: "\(source)_initial_sync")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if finished || syncMessagesEmitted {
                    return
                }
                emitSyncMessagesIfNeeded(source: "\(source)_delayed_sync")
            }
        }

        socket.on(clientEvent: .connect) { _, _ in
            print("🔌 [TempSocketSession] Socket connected.")
            os_log("🔌 [TempSocketSession] Socket connected.", log: log, type: .info)
            handleConnectedState(source: "connect_event")
        }

        socket.on(clientEvent: .statusChange) { data, _ in
            let socketStatus = socket.status

            socketStepLog(
                traceId: seedTraceId,
                messageId: seedMessageId,
                roomId: seedRoomId,
                stepKey: "ios_socket_status_changed",
                stepMessage: "Socket client status changed to \(socketStatus.description)",
                status: "info",
                payload: [
                    "status": socketStatus.description,
                    "status_raw": socketStatus.rawValue,
                    "status_data": String(describing: data)
                ]
            )

            if socketStatus == .connected {
                handleConnectedState(source: "status_change_connected")
            }
        }

        socket.onAny { event in
            let name = event.event
            let items = event.items ?? []
            let payloadDescription = String(describing: items)
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            print("🔌 [TempSocketSession] Incoming event=\(name) payloadCount=\(items.count) payload=\(payloadDescription)")
            os_log("🔌 [TempSocketSession] Incoming event=%{public}@ payloadCount=%{public}d payload=%{public}@",
                   log: log,
                   type: .debug,
                   name,
                   items.count,
                   payloadDescription)
            socketStepLog(
                traceId: seedTraceId,
                messageId: seedMessageId,
                roomId: seedRoomId,
                stepKey: "ios_socket_event_received",
                stepMessage: "iOS received socket event \(name)",
                status: "info",
                payload: [
                    "event": name,
                    "payload_count": items.count
                ]
            )

            if firstSocketEventAtMs == nil {
                firstSocketEventAtMs = nowMs
                socketStepLog(
                    traceId: seedTraceId,
                    messageId: seedMessageId,
                    roomId: seedRoomId,
                    stepKey: "ios_socket_first_event_received",
                    stepMessage: "First socket event arrived for this temporary session.",
                    status: "success",
                    payload: [
                        "event": name,
                        "first_event_elapsed_ms": nowMs - sessionStartMs,
                        "connect_to_first_event_ms": nowMs - connectAttemptStartedAtMs
                    ]
                )
            }

            if name == "sync_messages_response" {
                syncResponseReceived = true
                resetIdleTimer()
                MessageFlowLogger.log(
                    traceId: seedTraceId,
                    messageId: seedMessageId,
                    roomId: seedRoomId,
                    stepKey: "ios_sync_messages_response_received",
                    stepMessage: "iOS received sync_messages_response from server",
                    channel: "socket",
                    status: "success",
                    payload: [
                        "event": name,
                        "payload_count": items.count
                    ]
                )
            }

            if name == "room:message_notification" {
                MessageFlowLogger.log(
                    traceId: seedTraceId,
                    messageId: seedMessageId,
                    roomId: seedRoomId,
                    stepKey: "ios_room_message_notification_received",
                    stepMessage: "iOS received room:message_notification while app was backgrounded",
                    channel: "socket",
                    status: "success",
                    payload: [
                        "event": name,
                        "payload_count": items.count
                    ]
                )

                if syncMessagesEmitted && !syncResponseReceived {
                    bufferedDirectEvents.append((name: name, items: items, queuedAtMs: nowMs))
                    socketStepLog(
                        traceId: seedTraceId,
                        messageId: seedMessageId,
                        roomId: seedRoomId,
                        stepKey: "ios_room_message_notification_buffered",
                        stepMessage: "Buffered direct room message event until sync backlog is applied",
                        status: "info",
                        payload: [
                            "event": name,
                            "payload_count": items.count,
                            "buffered_count": bufferedDirectEvents.count,
                            "payload_preview": String(payloadDescription.prefix(220))
                        ]
                    )
                    scheduleBufferedDirectEventFlushIfNeeded()
                    return
                }
            }

            if messageEvents.contains(name) {
                let didHandleCurrentEvent = handleSocketArgs(
                    event: name,
                    args: items,
                    syncReceived: syncResponseReceived,
                    clearMode: clearMode,
                    traceId: seedTraceId,
                    seedMessageId: seedMessageId,
                    seedRoomId: seedRoomId
                )

                var didDisplayNotification = didHandleCurrentEvent
                if name == "sync_messages_response" {
                    let didDisplayBuffered = flushBufferedDirectEvents(
                        reason: "sync_response_received",
                        syncReceivedForFlush: true
                    )
                    didDisplayNotification = didDisplayNotification || didDisplayBuffered
                }

                if didDisplayNotification {
                    noteNotificationOutput(eventName: name, at: nowMs)
                }
            }

            // sync_messages_response is the last meaningful server reply.
            // If it didn't produce a local notification (applyBulkSocketSync failed to parse
            // or decrypt), close the socket immediately so the unread API fallback starts
            // without burning the full 15-second idle timeout.
            if name == "sync_messages_response" && !messageReceived && !finished {
                socketStepLog(
                    traceId: seedTraceId,
                    messageId: seedMessageId,
                    roomId: seedRoomId,
                    stepKey: "ios_sync_response_finish_early",
                    stepMessage: "sync_messages_response payload did not yield a local notification; closing socket early to start unread API fallback without idle timeout",
                    status: "warning"
                )
                finish()
            }
        }

        socket.on(clientEvent: .error) { data, _ in
            print("🔌 [TempSocketSession] Socket error: \(data)")
            os_log("🔌 [TempSocketSession] Socket error %{public}@",
                   log: log,
                   type: .error,
                   String(describing: data))
            socketStepLog(
                traceId: seedTraceId,
                messageId: seedMessageId,
                roomId: seedRoomId,
                stepKey: "ios_socket_error",
                stepMessage: "Socket session received error event",
                status: "error",
                error: String(describing: data)
            )

            if !hasConnectedOnce {
                scheduleReconnect(reason: "socket_error_before_connect")
            }
        }

        socket.on(clientEvent: .disconnect) { data, _ in
            print("🔌 [TempSocketSession] Socket disconnected: \(data)")
            os_log("🔌 [TempSocketSession] Socket disconnected %{public}@",
                   log: log,
                   type: .info,
                   String(describing: data))
            socketStepLog(
                traceId: seedTraceId,
                messageId: seedMessageId,
                roomId: seedRoomId,
                stepKey: "ios_socket_disconnected",
                stepMessage: "Socket disconnected, releasing lock",
                status: "warning",
                payload: ["disconnect_data": String(describing: data)]
            )

            if messageReceived {
                finish()
                return
            }

            if connectAttemptsUsed < config.maxConnectAttempts {
                let reason = hasConnectedOnce ? "socket_disconnect_after_connect" : "socket_disconnect_before_connect"
                scheduleReconnect(reason: reason)
                return
            }

            finish()
        }

        connectSocket(reason: "initial")
        tryEmitSync(retries: 3)

        DispatchQueue.main.asyncAfter(deadline: .now() + config.maxSession) {
            if !finished {
                print("🔌 [TempSocketSession] Max session duration reached.")
                os_log("🔌 [TempSocketSession] Max session duration reached after %{public}.1f seconds",
                       log: log,
                       type: .error,
                       config.maxSession)
                socketStepLog(
                    traceId: seedTraceId,
                    messageId: seedMessageId,
                    roomId: seedRoomId,
                    stepKey: "ios_socket_max_duration_reached",
                    stepMessage: "Socket session hit maximum session duration",
                    status: "warning",
                    payload: ["max_session_sec": config.maxSession]
                )
                finish()
            }
        }
    }

    struct ExtensionCollectedMessage {
        let roomId: Int
        let title: String
        let body: String
        let messageId: String?
        let timestamp: Int64
        let source: String
    }

    struct ExtensionCollectionResult {
        let traceId: String
        let roomId: Int?
        let didConnect: Bool
        let syncResponseReceived: Bool
        let messages: [ExtensionCollectedMessage]
    }

    public static func collectMessagesForExtension(payloadData: [String: Any]?, completion: @escaping (ExtensionCollectionResult) -> Void) {
        let seedMessageId = stringValue(payloadData, keys: ["message_id", "messageId", "id"])
        let seedRoomId = intValue(payloadData, keys: ["room_id", "roomId"])
        let seedTraceId = seedMessageId.map { "msg-\($0)" } ?? "ios-nse-socket-\(Int(Date().timeIntervalSince1970 * 1000))"
        let sessionId = UUID().uuidString

        socketStepLog(
            traceId: seedTraceId,
            messageId: seedMessageId,
            roomId: seedRoomId,
            stepKey: "ios_nse_socket_collection_started",
            stepMessage: "Notification Service Extension started bounded socket collection for this push.",
            status: "start",
            payload: [
                "payload_keys": Array((payloadData ?? [:]).keys).sorted()
            ]
        )

        guard let baseConfig = resolveConfig(payloadData: payloadData) else {
            socketStepLog(
                traceId: seedTraceId,
                messageId: seedMessageId,
                roomId: seedRoomId,
                stepKey: "ios_nse_socket_config_missing",
                stepMessage: "Notification Service Extension could not start socket collection because shared auth or socket configuration was missing.",
                status: "error",
                payload: [
                    "has_token": (SafeStorageStore.get("token") ?? SafeStorageStore.get("authToken")) != nil,
                    "has_base_url": (SafeStorageStore.get("backendBaseUrl") ?? SafeStorageStore.get("backend_url") ?? SafeStorageStore.get("apiBaseUrl") ?? SafeStorageStore.get("api_base_url") ?? SafeStorageStore.get("serverUrl") ?? SafeStorageStore.get("server_url")) != nil
                ]
            )
            completion(ExtensionCollectionResult(
                traceId: seedTraceId,
                roomId: seedRoomId,
                didConnect: false,
                syncResponseReceived: false,
                messages: []
            ))
            return
        }

        let config = SessionConfig(
            jwtToken: baseConfig.jwtToken,
            socketUrl: baseConfig.socketUrl,
            socketPath: baseConfig.socketPath,
            enableQueryAuth: baseConfig.enableQueryAuth,
            allowPollingFallback: baseConfig.allowPollingFallback,
            preferPolling: baseConfig.preferPolling,
            idleTimeout: 1.2,
            maxSession: 6.0,
            connectTimeout: 2.5,
            maxConnectAttempts: 1,
            reconnectDelay: 0.5
        )

        guard let url = URL(string: config.socketUrl) else {
            socketStepLog(
                traceId: seedTraceId,
                messageId: seedMessageId,
                roomId: seedRoomId,
                stepKey: "ios_nse_socket_url_invalid",
                stepMessage: "Notification Service Extension resolved an invalid socket URL and aborted bounded socket collection.",
                status: "error",
                payload: ["socket_url": config.socketUrl]
            )
            completion(ExtensionCollectionResult(
                traceId: seedTraceId,
                roomId: seedRoomId,
                didConnect: false,
                syncResponseReceived: false,
                messages: []
            ))
            return
        }

        var socketOptions: SocketIOClientConfiguration = [
            .forceNew(true),
            .reconnects(false),
            .log(true),
            .version(.three),
            .path(config.socketPath),
            .connectParams([
                "token": config.jwtToken,
                "authToken": config.jwtToken,
                "auth[token]": config.jwtToken,
                "access_token": config.jwtToken,
                "jwt": config.jwtToken
            ]),
            .extraHeaders([
                "Authorization": "Bearer \(config.jwtToken)"
            ]),
            .compress
        ]
        if config.preferPolling {
            socketOptions.insert(.forcePolling(true))
        } else if !config.allowPollingFallback {
            socketOptions.insert(.forceWebsockets(true))
        }

        let manager = SocketManager(socketURL: url, config: socketOptions)
        retainManager(manager, for: sessionId)
        let socket = manager.defaultSocket

        var finished = false
        var didConnect = false
        var syncMessagesEmitted = false
        var syncResponseReceived = false
        var bufferedDirectEvents: [(name: String, items: [Any])] = []
        var bufferedFlushWorkItem: DispatchWorkItem?
        var idleWorkItem: DispatchWorkItem?
        var collectedMessages: [ExtensionCollectedMessage] = []

        func resetIdleFinish() {
            idleWorkItem?.cancel()
            let workItem = DispatchWorkItem {
                guard !finished else { return }
                finishSession()
            }
            idleWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + config.idleTimeout, execute: workItem)
        }

        func appendMessages(_ incoming: [ExtensionCollectedMessage]) {
            guard !incoming.isEmpty else { return }

            var seenIds = Set(collectedMessages.compactMap { normalizedMessageId($0.messageId) })
            var seenFingerprints = Set(collectedMessages.map { "\($0.roomId)|\($0.title)|\($0.body)|\($0.timestamp)" })

            for message in incoming.sorted(by: { $0.timestamp < $1.timestamp }) {
                if let messageId = normalizedMessageId(message.messageId) {
                    if SharedNotificationState.wasMessageShown(messageId) || seenIds.contains(messageId) {
                        continue
                    }
                    seenIds.insert(messageId)
                }

                let fingerprint = "\(message.roomId)|\(message.title)|\(message.body)|\(message.timestamp)"
                if seenFingerprints.contains(fingerprint) {
                    continue
                }
                seenFingerprints.insert(fingerprint)
                collectedMessages.append(message)
            }

            if !collectedMessages.isEmpty {
                resetIdleFinish()
            }
        }

        func flushBufferedDirectEvents() {
            bufferedFlushWorkItem?.cancel()
            bufferedFlushWorkItem = nil
            guard !bufferedDirectEvents.isEmpty else { return }
            let queued = bufferedDirectEvents
            bufferedDirectEvents.removeAll()
            for item in queued {
                appendMessages(collectedMessagesForEvent(event: item.name, args: item.items))
            }
        }

        func scheduleBufferedDirectFlushIfNeeded() {
            guard bufferedFlushWorkItem == nil else { return }
            let workItem = DispatchWorkItem {
                guard !finished else { return }
                flushBufferedDirectEvents()
            }
            bufferedFlushWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
        }

        func finishSession() {
            if finished { return }
            finished = true
            bufferedFlushWorkItem?.cancel()
            idleWorkItem?.cancel()
            flushBufferedDirectEvents()
            socket.removeAllHandlers()
            socket.disconnect()
            releaseManager(for: sessionId)
            socketStepLog(
                traceId: seedTraceId,
                messageId: seedMessageId,
                roomId: seedRoomId,
                stepKey: "ios_nse_socket_collection_finished",
                stepMessage: collectedMessages.isEmpty
                    ? "Notification Service Extension finished socket collection without decrypted message results."
                    : "Notification Service Extension finished socket collection with decrypted message results.",
                status: collectedMessages.isEmpty ? "info" : "success",
                payload: [
                    "did_connect": didConnect,
                    "sync_response_received": syncResponseReceived,
                    "message_count": collectedMessages.count,
                    "display_candidate_message_id": collectedMessages.sorted(by: { $0.timestamp < $1.timestamp }).last?.messageId as Any
                ]
            )
            completion(ExtensionCollectionResult(
                traceId: seedTraceId,
                roomId: seedRoomId,
                didConnect: didConnect,
                syncResponseReceived: syncResponseReceived,
                messages: collectedMessages.sorted(by: { $0.timestamp < $1.timestamp })
            ))
        }

        func emitJoinRoomAndSync() {
            if let roomId = seedRoomId, roomId > 0 {
                socket.emit("join_room", String(roomId))
            }

            guard !syncMessagesEmitted else { return }
            guard socket.status == .connected else { return }
            syncMessagesEmitted = true
            socket.emit("sync_messages")
            resetIdleFinish()
        }

        socket.on(clientEvent: .connect) { _, _ in
            didConnect = true
            socketStepLog(
                traceId: seedTraceId,
                messageId: seedMessageId,
                roomId: seedRoomId,
                stepKey: "ios_nse_socket_connected",
                stepMessage: "Notification Service Extension connected the temporary socket session.",
                status: "success"
            )
            emitJoinRoomAndSync()
        }

        socket.on(clientEvent: .statusChange) { _, _ in
            if socket.status == .connected {
                didConnect = true
                emitJoinRoomAndSync()
            }
        }

        socket.onAny { event in
            guard !finished else { return }
            let name = event.event
            let items = event.items ?? []

            if name == "sync_messages_response" {
                syncResponseReceived = true
                socketStepLog(
                    traceId: seedTraceId,
                    messageId: seedMessageId,
                    roomId: seedRoomId,
                    stepKey: "ios_nse_sync_messages_response_received",
                    stepMessage: "Notification Service Extension received sync_messages_response during bounded socket collection.",
                    status: "success",
                    payload: ["payload_count": items.count]
                )
                appendMessages(collectedMessagesForEvent(event: name, args: items))
                flushBufferedDirectEvents()
                resetIdleFinish()
                return
            }

            if name == "room:message_notification" && syncMessagesEmitted && !syncResponseReceived {
                bufferedDirectEvents.append((name: name, items: items))
                scheduleBufferedDirectFlushIfNeeded()
                return
            }

            if messageEvents.contains(name) {
                appendMessages(collectedMessagesForEvent(event: name, args: items))
            }
        }

        socket.on(clientEvent: .error) { _, _ in
            if !didConnect {
                finishSession()
            }
        }

        socket.on(clientEvent: .disconnect) { _, _ in
            finishSession()
        }

        socket.connect(withPayload: [
            "token": config.jwtToken,
            "authToken": config.jwtToken
        ], timeoutAfter: config.connectTimeout) {
            guard !finished else { return }
            if socket.status != .connected {
                finishSession()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + config.maxSession) {
            guard !finished else { return }
            finishSession()
        }
    }

    private struct SessionConfig {
        let jwtToken: String
        let socketUrl: String
        let socketPath: String
        let enableQueryAuth: Bool
        let allowPollingFallback: Bool
        let preferPolling: Bool
        let idleTimeout: TimeInterval
        let maxSession: TimeInterval
        let connectTimeout: TimeInterval
        let maxConnectAttempts: Int
        let reconnectDelay: TimeInterval

        var isValid: Bool { !jwtToken.isEmpty && !socketUrl.isEmpty }
    }

    private static func resolveConfig(payloadData: [String: Any]?) -> SessionConfig? {
        let jwt = SafeStorageStore.get("token") ?? SafeStorageStore.get("authToken") ?? ""
        let socketFromPayload = firstNonEmpty(
            payloadData?["socketUrl"] as? String,
            payloadData?["socket_url"] as? String,
            payloadData?["websocketUrl"] as? String,
            payloadData?["websocket_url"] as? String,
            payloadData?["wsUrl"] as? String,
            payloadData?["ws_url"] as? String
        )
        let socketFromPrefs = firstNonEmpty(
            SafeStorageStore.get("socketUrl"),
            SafeStorageStore.get("socket_url"),
            SafeStorageStore.get("websocketUrl"),
            SafeStorageStore.get("websocket_url")
        )
        let socketFromBasePrefs = firstNonEmpty(
            SafeStorageStore.get("backendBaseUrl"),
            SafeStorageStore.get("backend_url"),
            SafeStorageStore.get("apiBaseUrl"),
            SafeStorageStore.get("api_base_url"),
            SafeStorageStore.get("serverUrl"),
            SafeStorageStore.get("server_url")
        )
        let base = socketFromPayload ?? socketFromPrefs ?? socketFromBasePrefs ?? defaultSocketURL

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

        let normalizedSocketBase = normalizeSocketBaseUrl(base)
        let explicitPath = firstNonEmpty(
            payloadData?["socketPath"] as? String,
            payloadData?["socket_path"] as? String,
            SafeStorageStore.get("socketPath"),
            SafeStorageStore.get("socket_path")
        )
        let endpoint = resolveSocketEndpoint(baseUrl: normalizedSocketBase, explicitPath: explicitPath)
        let enableQueryAuth = boolValue(
            payloadData,
            keys: ["socketQueryAuth", "socket_query_auth", "useQueryAuth", "use_query_auth"],
            fallback: boolFromStorage(keys: ["socketQueryAuth", "socket_query_auth", "useQueryAuth", "use_query_auth"], defaultValue: defaultEnableQueryAuth)
        )
        let allowPollingFallback = boolValue(
            payloadData,
            keys: ["socketAllowPolling", "socket_allow_polling", "allowPolling", "allow_polling"],
            fallback: boolFromStorage(keys: ["socketAllowPolling", "socket_allow_polling", "allowPolling", "allow_polling"], defaultValue: defaultAllowPollingFallback)
        )
        let preferPolling = boolValue(
            payloadData,
            keys: ["socketPreferPolling", "socket_prefer_polling", "preferPolling", "prefer_polling"],
            fallback: boolFromStorage(keys: ["socketPreferPolling", "socket_prefer_polling", "preferPolling", "prefer_polling"], defaultValue: defaultPreferPolling)
        )

        return SessionConfig(
            jwtToken: jwt,
            socketUrl: endpoint.baseUrl,
            socketPath: endpoint.path,
            enableQueryAuth: enableQueryAuth,
            allowPollingFallback: allowPollingFallback,
            preferPolling: preferPolling,
            idleTimeout: defaultIdleTimeout,
            maxSession: defaultMaxSession,
            connectTimeout: defaultConnectTimeout,
            maxConnectAttempts: defaultConnectAttempts,
            reconnectDelay: defaultReconnectDelay
        )
    }

    private static func parseBool(_ raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        if let value = raw as? NSNumber { return value.boolValue }
        if let value = raw as? String {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes", "on", "enabled"].contains(normalized) {
                return true
            }
            if ["0", "false", "no", "off", "disabled"].contains(normalized) {
                return false
            }
        }
        return nil
    }

    private static func boolValue(_ payload: [String: Any]?, keys: [String], fallback: Bool) -> Bool {
        guard let payload else { return fallback }
        for key in keys {
            if let parsed = parseBool(payload[key]) {
                return parsed
            }
        }
        return fallback
    }

    private static func boolFromStorage(keys: [String], defaultValue: Bool) -> Bool {
        for key in keys {
            if let parsed = parseBool(SafeStorageStore.get(key)) {
                return parsed
            }
        }
        return defaultValue
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                continue
            }
            return raw
        }
        return nil
    }

    private static func normalizedSocketPath(_ raw: String?) -> String {
        guard let raw else { return "/socket.io" }
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty || path == "/" {
            return "/socket.io"
        }
        if !path.hasPrefix("/") {
            path = "/\(path)"
        }
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private static func resolveSocketEndpoint(baseUrl: String, explicitPath: String?) -> (baseUrl: String, path: String) {
        guard var components = URLComponents(string: baseUrl),
              let scheme = components.scheme,
              let host = components.host else {
            return (baseUrl: baseUrl, path: normalizedSocketPath(explicitPath))
        }

        let detectedPath: String = {
            let existing = components.path.trimmingCharacters(in: .whitespacesAndNewlines)
            if existing.isEmpty || existing == "/" {
                return normalizedSocketPath(explicitPath)
            }
            return normalizedSocketPath(explicitPath ?? existing)
        }()

        var root = URLComponents()
        root.scheme = scheme
        root.host = host
        root.port = components.port
        let rootUrl = root.string ?? baseUrl
        return (baseUrl: rootUrl, path: detectedPath)
    }

    private static func normalizeSocketBaseUrl(_ baseUrl: String) -> String {
        var normalized = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasSuffix("/") {
            normalized = String(normalized.dropLast())
        }
        if normalized.lowercased().hasPrefix("wss://") {
            normalized = "https://" + String(normalized.dropFirst(6))
        } else if normalized.lowercased().hasPrefix("ws://") {
            normalized = "http://" + String(normalized.dropFirst(5))
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

    private static func extractedSocketPayloadDictionaries(from args: [Any]) -> [[String: Any]] {
        args.compactMap { arg in
            arg as? [String: Any] ?? (arg as? NSDictionary as? [String: Any])
        }
    }

    private static func extractedBulkSyncRecords(from dicts: [[String: Any]]) -> [[String: Any]] {
        dicts.flatMap { dict -> [[String: Any]] in
            let raw = dict["messages"]
            if let arr = raw as? [[String: Any]], !arr.isEmpty {
                return arr
            }
            if let nsArr = raw as? NSArray, nsArr.count > 0 {
                let unwrapped: [[String: Any]] = nsArr.compactMap { item in
                    (item as? [String: Any]) ?? (item as? NSDictionary as? [String: Any])
                }
                if !unwrapped.isEmpty {
                    return unwrapped
                }
            }
            if let arr = raw as? [NSDictionary], !arr.isEmpty {
                let unwrapped = arr.compactMap { $0 as? [String: Any] }
                if !unwrapped.isEmpty {
                    return unwrapped
                }
            }
            return [dict]
        }
    }

    private static func collectedMessagesForEvent(event: String, args: [Any]) -> [ExtensionCollectedMessage] {
        let dicts = extractedSocketPayloadDictionaries(from: args)
        let records = bulkSyncSocketEvents.contains(event)
            ? extractedBulkSyncRecords(from: dicts)
            : dicts

        return records.compactMap { payload in
            guard let fields = normalizedFields(from: payload) else { return nil }
            return ExtensionCollectedMessage(
                roomId: fields.roomId,
                title: fields.title,
                body: fields.body,
                messageId: fields.messageId,
                timestamp: fields.timestamp,
                source: event
            )
        }
    }

    private static func payloadKeysDescription(_ payload: [String: Any]) -> [String] {
        Array(payload.keys).sorted()
    }

    private static func payloadTypeDescription(_ value: Any?) -> String {
        guard let value else { return "nil" }
        return String(describing: type(of: value))
    }

    private static func handleSocketArgs(event: String, args: [Any], syncReceived: Bool, clearMode: Bool, traceId: String, seedMessageId: String?, seedRoomId: Int?) -> Bool {
        print("🔌 [TempSocketSession] handleSocketArgs event=\(event) argsCount=\(args.count)")
        guard !args.isEmpty else {
            socketStepLog(
                traceId: traceId,
                messageId: seedMessageId,
                roomId: seedRoomId,
                stepKey: "ios_socket_event_empty_payload",
                stepMessage: "Socket event \(event) had no payload args",
                status: "warning"
            )
            return false
        }

        let dicts: [[String: Any]] = args.compactMap { arg in
            arg as? [String: Any] ?? (arg as? NSDictionary as? [String: Any])
        }

        if bulkSyncSocketEvents.contains(event) {
            let topLevelKeys = dicts.enumerated().map { index, dict in
                ["arg_index": index, "keys": payloadKeysDescription(dict)] as [String : Any]
            }
            socketStepLog(
                traceId: traceId,
                messageId: seedMessageId,
                roomId: seedRoomId,
                stepKey: "ios_socket_bulk_sync_payload_inspected",
                stepMessage: "Inspected top-level socket payload dictionaries before bulk sync parsing for event \(event)",
                status: "info",
                payload: [
                    "args_count": args.count,
                    "dict_count": dicts.count,
                    "top_level": topLevelKeys
                ]
            )
        }

        if bulkSyncSocketEvents.contains(event) {
            socketStepLog(
                traceId: traceId,
                messageId: seedMessageId,
                roomId: seedRoomId,
                stepKey: "ios_socket_bulk_sync_processing",
                stepMessage: "Processing bulk sync socket payload for event \(event)",
                status: "start",
                payload: ["records": dicts.count]
            )
            return applyBulkSocketSync(dicts: dicts, clearMode: clearMode, clearRoomHint: seedRoomId)
            
        }

        var handled = false
        for dict in dicts {
            if applySingleSocketRecord(dict, isSync: false) {
                handled = true
            } else if syncReceived, handleUnreadApiRecord(dict) {
                handled = true
            }
        }
        socketStepLog(
            traceId: traceId,
            messageId: seedMessageId,
            roomId: seedRoomId,
            stepKey: "ios_socket_event_processed",
            stepMessage: handled ? "Socket event \(event) produced notification output" : "Socket event \(event) did not produce notification output",
            status: handled ? "success" : "info",
            payload: ["records": dicts.count]
        )
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
              roomId > 0 else {
            socketStepLog(
                traceId: traceIdForSocket(messageId: stringValue(payload, keys: ["message_id", "messageId", "id"]), roomId: nil),
                messageId: stringValue(payload, keys: ["message_id", "messageId", "id"]),
                roomId: nil,
                stepKey: "ios_socket_payload_invalid_room",
                stepMessage: "Socket payload skipped because room id was missing or invalid",
                status: "warning",
                payload: [
                    "keys": payloadKeysDescription(payload),
                    "room_id_type": payloadTypeDescription(payload["room_id"]),
                    "roomId_type": payloadTypeDescription(payload["roomId"]),
                    "message_id": stringValue(payload, keys: ["message_id", "messageId", "id"]) ?? ""
                ]
            )
            return nil
        }

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

        let finalTitle: String = {
            if let username, !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let roomName, !roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if username.caseInsensitiveCompare(roomName) == .orderedSame {
                    return roomName
                }
                return "\(username) in \(roomName)"
            }
            if let roomName, !roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return roomName
            }
            if let username, !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return username
            }
            return "New message"
        }()
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

        socketStepLog(
            traceId: traceIdForSocket(messageId: messageId, roomId: roomId),
            messageId: messageId,
            roomId: roomId,
            userId: senderId > 0 ? senderId : nil,
            stepKey: "ios_socket_payload_normalized",
            stepMessage: "Socket payload normalized and decrypted for notification",
            status: "success",
            payload: [
                "keys": payloadKeysDescription(payload),
                "has_username": username != nil,
                "has_room_name": roomName != nil,
                "has_message_text": messageText != nil,
                "timestamp_ms": timestampMs
            ]
        )

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
        let didDisplay = NotificationHelper.showRoomNotification(
            title: fields.title,
            body: fields.body,
            roomId: fields.roomId,
            messageId: fields.messageId,
            timestamp: fields.timestamp,
            isSync: isSync
        )
        let traceId = (fields.messageId != nil && !(fields.messageId ?? "").isEmpty)
            ? "msg-\(fields.messageId!)"
            : "ios-socket-\(fields.roomId)-\(fields.timestamp)"
        if didDisplay {
            MessageFlowLogger.log(
                traceId: traceId,
                messageId: fields.messageId,
                roomId: fields.roomId,
                stepKey: "ios_notification_from_socket",
                stepMessage: isSync ? "iOS displayed notification from socket sync response" : "iOS displayed notification from socket event",
                channel: "socket",
                status: "success",
                payload: [
                    "title": fields.title,
                    "body_preview": String(fields.body.prefix(120))
                ]
            )
            socketStepLog(
                traceId: traceId,
                messageId: fields.messageId,
                roomId: fields.roomId,
                stepKey: "ios_socket_single_record_notified",
                stepMessage: isSync ? "Socket sync record displayed notification" : "Socket direct event record displayed notification",
                status: "success",
                payload: [
                    "title_preview": String(fields.title.prefix(80)),
                    "body_preview": String(fields.body.prefix(120))
                ]
            )
        } else {
            socketStepLog(
                traceId: traceId,
                messageId: fields.messageId,
                roomId: fields.roomId,
                stepKey: "ios_socket_single_record_deduped",
                stepMessage: "Socket record was deduped and did not display a new notification",
                status: "info"
            )
        }
        return didDisplay
    }

    private static func applyBulkSocketSync(dicts: [[String: Any]], clearMode: Bool = false, clearRoomHint: Int? = nil) -> Bool {
        // Server sends sync_messages_response as { messages: [...] }.
        // Socket.IO-Swift delivers nested arrays as NSArray<NSDictionary>, which does NOT
        // always bridge to [[String:Any]] via a direct `as?` cast — iterate NSArray explicitly.
        let records: [[String: Any]] = dicts.flatMap { dict -> [[String: Any]] in
            let raw = dict["messages"]
            socketStepLog(
                traceId: traceIdForSocket(messageId: stringValue(dict, keys: ["message_id", "messageId", "id"]), roomId: intValue(dict, keys: ["room_id", "roomId"])),
                messageId: stringValue(dict, keys: ["message_id", "messageId", "id"]),
                roomId: intValue(dict, keys: ["room_id", "roomId"]),
                stepKey: "ios_socket_bulk_sync_wrapper_detected",
                stepMessage: "Inspecting bulk sync wrapper before extracting message records",
                status: "info",
                payload: [
                    "top_level_keys": payloadKeysDescription(dict),
                    "messages_type": payloadTypeDescription(raw),
                    "messages_count_hint": (raw as? NSArray)?.count ?? (raw as? [[String: Any]])?.count ?? (raw as? [NSDictionary])?.count ?? 0
                ]
            )
            // Path 1: Swift-native bridge succeeded
            if let arr = raw as? [[String: Any]], !arr.isEmpty { return arr }
            // Path 2: NSArray of NSDictionary (most common from Socket.IO-Swift JSON parser)
            if let nsArr = raw as? NSArray, nsArr.count > 0 {
                let unwrapped: [[String: Any]] = nsArr.compactMap { item in
                    (item as? [String: Any]) ?? (item as? NSDictionary as? [String: Any])
                }
                if !unwrapped.isEmpty { return unwrapped }
            }
            // Path 3: typed [NSDictionary]
            if let arr = raw as? [NSDictionary], !arr.isEmpty {
                let unwrapped = arr.compactMap { $0 as? [String: Any] }
                if !unwrapped.isEmpty { return unwrapped }
            }
            // No messages wrapper found — treat as a bare message record
            return [dict]
        }
        socketStepLog(
            traceId: traceIdForSocket(messageId: nil, roomId: nil, fallbackPrefix: "ios-socket-sync"),
            stepKey: "ios_socket_bulk_sync_records_unwrapped",
            stepMessage: "Bulk sync wrapper inspection completed and candidate records were extracted",
            status: "info",
            payload: [
                "top_level_dicts": dicts.count,
                "candidate_records": records.count,
                "record_keys": records.prefix(5).map { payloadKeysDescription($0) }
            ]
        )
        var byRoom: [Int: [(title: String, body: String, messageId: String?, timestamp: Int64)]] = [:]
        for dict in records {
            guard let fields = normalizedFields(from: dict) else { continue }
            byRoom[fields.roomId, default: []].append((fields.title, fields.body, fields.messageId, fields.timestamp))
        }
        if byRoom.isEmpty {
            if clearMode, let clearRoomHint, clearRoomHint > 0 {
                NotificationHelper.reconcileRoomNotifications(
                    roomId: clearRoomHint,
                    unreadMessageIds: [],
                    source: "sync_messages_response(clear_mode_empty)"
                )
            }
            socketStepLog(
                traceId: traceIdForSocket(messageId: nil, roomId: nil, fallbackPrefix: "ios-socket-sync"),
                stepKey: "ios_socket_bulk_sync_empty",
                stepMessage: "Bulk sync payload had no valid message records",
                status: "info"
            )
            return false
        }
        var handled = false
        for (roomId, rows) in byRoom {
            let sorted = rows.sorted { $0.timestamp < $1.timestamp }
            if clearMode {
                let unreadIds = sorted.compactMap { normalizedMessageId($0.messageId) }
                NotificationHelper.reconcileRoomNotifications(
                    roomId: roomId,
                    unreadMessageIds: unreadIds,
                    source: "sync_messages_response(clear_mode)"
                )
            }
            socketStepLog(
                traceId: traceIdForSocket(messageId: sorted.last?.messageId ?? nil, roomId: roomId, fallbackPrefix: "ios-socket-sync"),
                messageId: sorted.last?.messageId ?? nil,
                roomId: roomId,
                stepKey: "ios_socket_bulk_sync_room_started",
                stepMessage: "Started bulk sync notification merge for room \(roomId)",
                status: "start",
                payload: ["records": sorted.count]
            )
            var shownCount = 0
            for row in sorted {
                let didShow = NotificationHelper.showRoomNotification(
                    title: row.title,
                    body: row.body,
                    roomId: roomId,
                    messageId: row.messageId,
                    timestamp: row.timestamp,
                    isSync: true
                )
                if didShow {
                    shownCount += 1
                    handled = true
                    socketStepLog(
                        traceId: traceIdForSocket(messageId: row.messageId, roomId: roomId, fallbackPrefix: "ios-socket-sync"),
                        messageId: row.messageId,
                        roomId: roomId,
                        stepKey: "ios_socket_bulk_sync_message_notified",
                        stepMessage: "Bulk sync displayed one unseen message notification in chronological order.",
                        status: "success",
                        payload: [
                            "title_preview": String(row.title.prefix(80)),
                            "body_preview": String(row.body.prefix(120)),
                            "timestamp": row.timestamp
                        ]
                    )
                }
            }
            if shownCount > 0 {
                socketStepLog(
                    traceId: traceIdForSocket(messageId: sorted.last?.messageId ?? nil, roomId: roomId, fallbackPrefix: "ios-socket-sync"),
                    messageId: sorted.last?.messageId ?? nil,
                    roomId: roomId,
                    stepKey: "ios_socket_bulk_sync_room_notified",
                    stepMessage: "Bulk sync produced a notification update for room \(roomId)",
                    status: "success",
                    payload: ["shown_count": shownCount]
                )
            } else {
                socketStepLog(
                    traceId: traceIdForSocket(messageId: sorted.last?.messageId ?? nil, roomId: roomId, fallbackPrefix: "ios-socket-sync"),
                    messageId: sorted.last?.messageId ?? nil,
                    roomId: roomId,
                    stepKey: "ios_socket_bulk_sync_room_deduped",
                    stepMessage: "Bulk sync room \(roomId) produced no new notification after filtering already-shown messages and room-level suppression.",
                    status: "info",
                    payload: ["shown_count": shownCount]
                )
            }
        }
        return handled
    }

    private static func handleUnreadApiRecord(_ item: [String: Any]) -> Bool {
        print("🔌 [TempSocketSession] handleUnreadApiRecord item=\(item)")
        return UnreadMessagesFetcher.notifyFromUnreadRecord(item)
    }
}

