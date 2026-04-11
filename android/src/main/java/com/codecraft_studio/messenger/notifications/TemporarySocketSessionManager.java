package com.codecraft_studio.messenger.notifications;

import android.content.Context;
import android.content.SharedPreferences;
import android.net.ConnectivityManager;
import android.net.NetworkInfo;
import android.text.TextUtils;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.net.URISyntaxException;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

import io.socket.client.IO;
import io.socket.client.Socket;
import io.socket.client.Ack;
import io.socket.engineio.client.transports.WebSocket;
import io.socket.engineio.client.transports.Polling;

/**
 * Opens a short-lived Socket.IO session triggered by FCM and auto-closes after idle timeout.
 */
final class TemporarySocketSessionManager {

    private static final String TAG = "TempSocketSession";

    private static final long DEFAULT_IDLE_TIMEOUT_MS = 30_000L;
    private static final long DEFAULT_CONNECT_TIMEOUT_MS = 20_000L;
    private static final long DEFAULT_MAX_SESSION_MS = 45_000L;
    private static final String DEFAULT_SOCKET_URL = "wss://4.rw";

    private static final Set<String> MESSAGE_EVENTS = new HashSet<>(Arrays.asList(
            "sync_messages_response",
            "sync:messages",
            // "room:new_message",
            // "room:message",
            "room:message_notification"
            // "notification:new",
            // "message:new",
            // "new_message",
            // "message"
    ));

    private TemporarySocketSessionManager() {
    }

    static boolean runSession(Context context, Map<String, String> payloadData) {
        Log.i(TAG, "[ENTRY][TEMP_SOCKET_SESSION] runSession()");
        Log.i(TAG, "runSession() payloadData=" + safePreviewMap(payloadData));
        final String sessionMessageId = firstNonEmpty(
            payloadData != null ? payloadData.get("message_id") : null,
            payloadData != null ? payloadData.get("messageId") : null,
            payloadData != null ? payloadData.get("id") : null
        );
        final Integer sessionRoomId = parseNullableInt(firstNonEmpty(
            payloadData != null ? payloadData.get("room_id") : null,
            payloadData != null ? payloadData.get("roomId") : null
        ));
        final String sessionTraceId = !TextUtils.isEmpty(sessionMessageId)
            ? "msg-" + sessionMessageId
            : "android-socket-" + System.currentTimeMillis();
        if (!isNetworkAvailable(context)) {
            Log.w(TAG, "Socket session aborted: No network connectivity.");
            return false;
        }

        SessionConfig config = resolveConfig(context, payloadData);
        if (!config.isValid()) {
            Log.i(TAG, "Socket session skipped, missing config (URL or Token).");
            return false;
        }

        Log.d(TAG, "Starting socket session with URL: " + config.socketUrl);

        final CountDownLatch sessionDone = new CountDownLatch(1);
        final AtomicBoolean finished = new AtomicBoolean(false);
        final AtomicBoolean messageReceived = new AtomicBoolean(false);
        final AtomicBoolean syncResponseReceived = new AtomicBoolean(false);

        final ScheduledExecutorService scheduler = Executors.newSingleThreadScheduledExecutor();
        final AtomicReference<ScheduledFuture<?>> idleFuture = new AtomicReference<>();
        final AtomicReference<Socket> socketRef = new AtomicReference<>();

        Runnable finishSession = () -> {
            if (finished.compareAndSet(false, true)) {
                Log.d(TAG, "Closing socket session (idle or max duration reached).");
                sessionDone.countDown();
            }
        };

        Runnable resetIdleTimer = () -> {
            ScheduledFuture<?> existing = idleFuture.getAndSet(null);
            if (existing != null) {
                existing.cancel(false);
            }
            if (!finished.get()) {
                ScheduledFuture<?> next = scheduler.schedule(finishSession, config.idleTimeoutMs, TimeUnit.MILLISECONDS);
                idleFuture.set(next);
            }
        };

        try {
            Socket socket = createSocket(config);
            socketRef.set(socket);

            socket.on(Socket.EVENT_CONNECT, args -> {
                Log.d(TAG, "Socket connected successfully.");
                MessageFlowLogger.log(
                        context,
                        sessionTraceId,
                        sessionMessageId,
                        sessionRoomId,
                        null,
                        "android_socket_connected",
                        "Android background socket connected after wake-up",
                        "socket",
                        "success",
                        null,
                        null
                );
                resetIdleTimer.run();
                
                if (payloadData != null) {
                    String roomId = firstNonEmpty(payloadData.get("roomId"), payloadData.get("room_id"));
                    if (!TextUtils.isEmpty(roomId)) {
                        Log.d(TAG, "Emitting join_room with roomId=" + roomId + " payloadData=" + safePreviewMap(payloadData));
                        socket.emit("join_room", roomId);
                    }
                }

                Log.d(TAG, "Emitting sync_messages with payloadData=" + safePreviewMap(payloadData));
                JSONObject syncPayload = new JSONObject();
                try {
                    if (sessionRoomId != null) {
                        syncPayload.put("room_id", sessionRoomId);
                    }
                    if (!TextUtils.isEmpty(sessionMessageId)) {
                        syncPayload.put("trigger_message_id", sessionMessageId);
                    }
                } catch (JSONException e) {
                    Log.e(TAG, "Error building syncPayload", e);
                }
                MessageFlowLogger.log(
                        context,
                        sessionTraceId,
                        sessionMessageId,
                        sessionRoomId,
                        null,
                        "android_sync_messages_emitted",
                        "Android emitted sync_messages after background socket connect",
                        "socket",
                        "success",
                        syncPayload,
                        null
                );
                socket.emit("sync_messages", (Ack) ackArgs -> {
                    Log.d(TAG, "Received sync_messages ACK args=" + safePreviewArgs(ackArgs));
                    JSONObject ackPayload = new JSONObject();
                    try {
                        ackPayload.put("ack_args_count", ackArgs != null ? ackArgs.length : 0);
                    } catch (JSONException e) {
                        Log.e(TAG, "Error building ackPayload", e);
                    }
                    MessageFlowLogger.log(
                            context,
                            sessionTraceId,
                            sessionMessageId,
                            sessionRoomId,
                            null,
                            "android_sync_messages_ack_received",
                            "Android received sync_messages ACK from server",
                            "socket",
                            "success",
                            ackPayload,
                            null
                    );
                    resetIdleTimer.run();
                });
            });

            socket.onAnyIncoming(args -> {
                if (args != null && args.length > 0) {
                    // Reset idle timer for ANY incoming data (including global:online_users)
                    resetIdleTimer.run();

                    // Log the raw payload to Logcat
                    Log.d(TAG, "RAW SOCKET DATA: " + Arrays.toString(args));

                    String event = String.valueOf(args[0]);
                    Object[] payloadArgs = args.length > 1 ? Arrays.copyOfRange(args, 1, args.length) : new Object[0];
                    Log.d(TAG, "Socket incoming event=" + event + " payloadCount=" + payloadArgs.length + " payload=" + safePreviewArgs(payloadArgs));

                    if ("sync_messages_response".equals(event)) {
                        syncResponseReceived.set(true);
                        Object payload = args.length > 1 ? args[1] : "no payload";
                        Log.d(TAG, "Received sync_messages_response, payload size: " + (payload != null ? payload.toString().length() : 0));
                    }

                    if (MESSAGE_EVENTS.contains(event)) {
                        String eventMessageId = extractMessageIdFromArgs(payloadArgs);
                        Integer eventRoomId = extractRoomIdFromArgs(payloadArgs);
                        Integer eventSenderId = extractSenderIdFromArgs(payloadArgs);
                        String eventTraceId = !TextUtils.isEmpty(eventMessageId) ? "msg-" + eventMessageId : sessionTraceId;
                        JSONObject eventPayload = new JSONObject();
                        try {
                            eventPayload.put("event", event);
                            eventPayload.put("payload_count", payloadArgs.length);
                            if (eventSenderId != null) {
                                eventPayload.put("sender_id", eventSenderId);
                            }
                        } catch (JSONException e) {
                            Log.e(TAG, "Error building eventPayload", e);
                        }

                        if ("sync_messages_response".equals(event)) {
                            MessageFlowLogger.log(
                                    context,
                                    eventTraceId,
                                    eventMessageId != null ? eventMessageId : sessionMessageId,
                                    eventRoomId != null ? eventRoomId : sessionRoomId,
                                    null,
                                    "android_sync_messages_response_received",
                                    "Android received sync_messages_response from server",
                                    "socket",
                                    "success",
                                    eventPayload,
                                    null
                            );
                        } else if ("room:message_notification".equals(event)) {
                            MessageFlowLogger.log(
                                    context,
                                    eventTraceId,
                                    eventMessageId != null ? eventMessageId : sessionMessageId,
                                    eventRoomId != null ? eventRoomId : sessionRoomId,
                                    null,
                                    "android_room_message_notification_received",
                                    "Android received room:message_notification while app was backgrounded",
                                    "socket",
                                    "success",
                                    eventPayload,
                                    null
                            );
                        }
                    }

                    if (MESSAGE_EVENTS.contains(event)) {
                        if (payloadArgs.length > 0 && handleSocketArgs(context, event, payloadArgs, syncResponseReceived.get())) {
                            messageReceived.set(true);
                        }
                    } else if (!"global:online_users".equals(event)) {
                        Log.v(TAG, "Received non-message event: " + event);
                    }
                }
            });

            socket.on(Socket.EVENT_CONNECT_ERROR, args -> {
                Log.w(TAG, "Socket connect error: " + firstArgToString(args) + " fullArgs=" + safePreviewArgs(args));
                finishSession.run();
            });

            socket.on("error", args -> {
                Log.w(TAG, "Socket error: " + firstArgToString(args) + " fullArgs=" + safePreviewArgs(args));
            });

            socket.on(Socket.EVENT_DISCONNECT, args -> {
                Log.d(TAG, "Socket disconnected. Reason: " + firstArgToString(args) + " fullArgs=" + safePreviewArgs(args));
                finishSession.run();
            });

            socket.connect();
            resetIdleTimer.run(); // Initial timeout for connection

            // Wait until session is done or max time limit is reached.
            if (!sessionDone.await(config.maxSessionMs, TimeUnit.MILLISECONDS)) {
                Log.i(TAG, "Socket session reached max time limit (" + config.maxSessionMs + "ms). Force closing.");
            }
        } catch (Exception e) {
            Log.w(TAG, "Socket session encountered an exception", e);
        } finally {
            scheduler.shutdownNow();
            Socket socket = socketRef.get();
            if (socket != null) {
                socket.off();
                socket.disconnect();
                socket.close();
            }
        }

        return messageReceived.get();
    }

    private static boolean isNetworkAvailable(Context context) {
        ConnectivityManager cm = (ConnectivityManager) context.getSystemService(Context.CONNECTIVITY_SERVICE);
        NetworkInfo activeNetwork = cm != null ? cm.getActiveNetworkInfo() : null;
        return activeNetwork != null && activeNetwork.isConnectedOrConnecting();
    }

    private static Integer parseNullableInt(String raw) {
        if (TextUtils.isEmpty(raw)) return null;
        try {
            return Integer.parseInt(raw);
        } catch (Exception e) {
            return null;
        }
    }

    private static boolean handleSocketArgs(Context context, String event, Object[] args, boolean syncReceived) {
        Log.i(TAG, "[ENTRY][TEMP_SOCKET_SESSION] handleSocketArgs() event=" + event + " args=" + (args == null ? 0 : args.length));
        if (args == null || args.length == 0) return false;
        boolean handled = false;
        for (Object arg : args) {
            boolean notified = "sync_messages_response".equals(event)
                    ? EncryptedMessageNotifier.notifyFromSyncMessagesResponse(context, arg)
                    : EncryptedMessageNotifier.notifyFromSocketPayload(context, arg);

            // Fallback: If socket payload parsing didn't produce a notification AND sync_messages_response was already received,
            // try parsing it as a raw unread API record.
            if (!notified && syncReceived && arg instanceof JSONObject) {
                if (EncryptedMessageNotifier.notifyFromUnreadApiRecord(context, (JSONObject) arg)) {
                    notified = true;
                }
            }

            if (notified) {
                MessageFlowLogger.log(
                        context,
                        "android-socket-" + System.currentTimeMillis(),
                        null,
                        null,
                        null,
                        "android_socket_event_processed",
                        "Android processed socket event and displayed/updated notification",
                        "socket",
                        "success",
                        null,
                        null
                );
                handled = true;
            }
        }
        return handled;
    }

    private static Socket createSocket(SessionConfig config) throws URISyntaxException {
        IO.Options options = new IO.Options();
        options.forceNew = true;
        options.reconnection = false;
        options.timeout = config.connectTimeoutMs;
        // Allow both WebSocket and Polling for better compatibility and fallback
        options.transports = new String[]{WebSocket.NAME, Polling.NAME};

        if (!setAuthIfSupported(options, config.jwtToken)) {
            options.query = "token=" + config.jwtToken;
        }
        return IO.socket(config.socketUrl, options);
    }

    private static boolean setAuthIfSupported(IO.Options options, String token) {
        try {
            java.lang.reflect.Field authField = IO.Options.class.getField("auth");
            Map<String, String> auth = new HashMap<>();
            auth.put("token", token);
            authField.set(options, auth);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    private static SessionConfig resolveConfig(Context context, Map<String, String> payloadData) {
        SharedPreferences prefs = context.getSharedPreferences("safe_storage", Context.MODE_PRIVATE);
        String jwtToken = firstNonEmpty(prefs.getString("token", null), prefs.getString("authToken", null));
        String baseUrl = firstNonEmpty(
                payloadData != null ? payloadData.get("socketUrl") : null,
                prefs.getString("socketUrl", null),
                DEFAULT_SOCKET_URL
        );

        return new SessionConfig(jwtToken, normalizeSocketBaseUrl(baseUrl), DEFAULT_IDLE_TIMEOUT_MS, DEFAULT_MAX_SESSION_MS, (int) DEFAULT_CONNECT_TIMEOUT_MS);
    }

    private static String normalizeSocketBaseUrl(String baseUrl) {
        if (TextUtils.isEmpty(baseUrl)) return null;
        String normalized = baseUrl.trim();
        if (normalized.endsWith("/")) normalized = normalized.substring(0, normalized.length() - 1);
        if (normalized.endsWith("/api")) normalized = normalized.substring(0, normalized.length() - 4);
        if (!normalized.contains("://")) normalized = "https://" + normalized;
        return normalized;
    }

    private static String firstArgToString(Object[] args) {
        return (args != null && args.length > 0) ? String.valueOf(args[0]) : "unknown";
    }

    private static JSONObject firstJsonObject(Object[] args) {
        if (args == null) return null;
        for (Object arg : args) {
            JSONObject object = firstJsonObject(arg);
            if (object != null) return object;
        }
        return null;
    }

    private static JSONObject firstJsonObject(Object value) {
        if (value instanceof JSONObject) {
            JSONObject json = (JSONObject) value;

            JSONArray messages = json.optJSONArray("messages");
            if (messages != null && messages.length() > 0 && messages.optJSONObject(0) != null) {
                return messages.optJSONObject(0);
            }

            JSONObject data = json.optJSONObject("data");
            if (data != null) {
                JSONObject nested = firstJsonObject(data);
                if (nested != null) return nested;
            }

            JSONObject message = json.optJSONObject("message");
            if (message != null) {
                return message;
            }

            return json;
        }

        if (value instanceof JSONArray) {
            JSONArray array = (JSONArray) value;
            for (int i = 0; i < array.length(); i++) {
                JSONObject object = firstJsonObject(array.opt(i));
                if (object != null) return object;
            }
        }

        return null;
    }

    private static String extractMessageIdFromArgs(Object[] args) {
        JSONObject json = firstJsonObject(args);
        if (json == null) return null;
        return firstNonEmpty(
                json.optString("message_id", null),
                json.optString("messageId", null),
                json.optString("id", null)
        );
    }

    private static Integer extractRoomIdFromArgs(Object[] args) {
        JSONObject json = firstJsonObject(args);
        if (json == null) return null;
        int roomId = json.optInt("room_id", json.optInt("roomId", 0));
        return roomId > 0 ? roomId : null;
    }

    private static Integer extractSenderIdFromArgs(Object[] args) {
        JSONObject json = firstJsonObject(args);
        if (json == null) return null;
        int senderId = json.optInt("sender_id", json.optInt("senderId", json.optInt("user_id", json.optInt("userId", 0))));
        return senderId > 0 ? senderId : null;
    }

    private static String firstNonEmpty(String... values) {
        for (String v : values) if (!TextUtils.isEmpty(v) && !"null".equalsIgnoreCase(v)) return v;
        return null;
    }

    private static String safePreviewMap(Map<String, String> data) {
        if (data == null || data.isEmpty()) return "{}";
        return safePreviewString(data.toString());
    }

    private static String safePreviewArgs(Object[] args) {
        if (args == null || args.length == 0) return "[]";
        return safePreviewString(Arrays.toString(args));
    }

    private static String safePreviewString(String value) {
        if (value == null) return "null";
        int max = 1200;
        if (value.length() <= max) return value;
        return value.substring(0, max) + "...(truncated," + value.length() + " chars)";
    }

    private static final class SessionConfig {
        final String jwtToken;
        final String socketUrl;
        final long idleTimeoutMs;
        final long maxSessionMs;
        final int connectTimeoutMs;

        SessionConfig(String jwtToken, String socketUrl, long idleTimeout, long maxSession, int connectTimeout) {
            this.jwtToken = jwtToken;
            this.socketUrl = socketUrl;
            this.idleTimeoutMs = idleTimeout;
            this.maxSessionMs = maxSession;
            this.connectTimeoutMs = connectTimeout;
        }

        boolean isValid() {
            return !TextUtils.isEmpty(jwtToken) && !TextUtils.isEmpty(socketUrl);
        }
    }
}
