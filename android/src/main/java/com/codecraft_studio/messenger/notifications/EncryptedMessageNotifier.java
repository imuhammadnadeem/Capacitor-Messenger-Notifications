package com.codecraft_studio.messenger.notifications;

import android.app.ActivityManager;
import android.content.Context;
import android.content.SharedPreferences;
import android.text.TextUtils;
import android.util.Log;
import androidx.annotation.Nullable;
import com.getcapacitor.JSObject;
import java.text.SimpleDateFormat;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TimeZone;
import org.json.JSONArray;
import org.json.JSONObject;

final class EncryptedMessageNotifier {

    private static final String TAG = "EncryptedMessageNotifier";

    private EncryptedMessageNotifier() {}

    static boolean notifyFromUnreadApiRecord(Context context, JSONObject item) {
        Log.d(TAG, "notifyFromUnreadApiRecord() item=" + item.toString());
        return notifyFromNormalizedRecord(context, normalizeIncomingMessageRecord(item), false, false);
    }

    static boolean notifyFromPushData(Context context, Map<String, String> payloadData) {
        Log.d(TAG, "notifyFromPushData() data=" + payloadData.toString());
        if (payloadData == null || payloadData.isEmpty()) {
            return false;
        }

        int roomId = parseInt(firstNonEmpty(payloadData.get("roomId"), payloadData.get("room_id")), 0);
        int senderId = parseInt(firstNonEmpty(payloadData.get("senderId"), payloadData.get("sender_id")), 0);

        String rawRoomName = firstNonEmpty(
            payloadData.get("encrypted_room_name"),
            payloadData.get("encryptedRoomName"),
            payloadData.get("room_name")
        );
        String roomName = decryptRoomName(context, roomId, rawRoomName);

        if (roomId > 0) {
            if (isActuallyDecrypted(roomName)) {
                NotificationHelper.setRoomName(context, roomId, roomName);
            } else {
                String cached = NotificationHelper.getRoomName(roomId);
                if (cached != null) roomName = cached;
            }
        }

        String messageId = firstNonEmpty(payloadData.get("id"), payloadData.get("messageId"), payloadData.get("message_id"));
        long timestamp = parseTimestamp(payloadData.get("created_at"));

        String username = decryptUserName(
            context,
            senderId,
            firstNonEmpty(
                payloadData.get("encrypted_username"),
                payloadData.get("encryptedUsername"),
                payloadData.get("sender_name"),
                payloadData.get("senderName"),
                payloadData.get("username")
            )
        );
        String avatarSvg = firstNonEmpty(payloadData.get("avatar_svg"), payloadData.get("avatarSvg"));

        String message = decryptRoomMessage(
            context,
            roomId,
            firstNonEmpty(
                payloadData.get("encrypted_message"),
                payloadData.get("encryptedMessage"),
                payloadData.get("body"),
                payloadData.get("message"),
                payloadData.get("ciphertext")
            )
        );

        if (isGenericOrEmpty(message)) {
            if (!TextUtils.isEmpty(roomName) && isActuallyDecrypted(roomName)) {
                message = "New message in " + roomName;
            }
        }

        return showNotification(
            context,
            roomId,
            senderId,
            username,
            roomName,
            message,
            firstNonEmpty(payloadData.get("title"), payloadData.get("notification_title")),
            firstNonEmpty(payloadData.get("body"), payloadData.get("message")),
            messageId,
            timestamp,
            false,
            false,
            avatarSvg
        );
    }

    static boolean notifyFromSocketPayload(Context context, Object payload) {
        Log.d(TAG, "notifyFromSocketPayload()");
        if (payload instanceof JSONArray) {
            return notifyFromSocketMessagesArray(context, (JSONArray) payload);
        }

        if (!(payload instanceof JSONObject)) {
            Log.w(TAG, "Socket payload is not a JSONObject or JSONArray");
            return false;
        }

        JSONObject json = (JSONObject) payload;
        JSONArray messages = json.optJSONArray("messages");
        if (messages != null && messages.length() > 0) {
            return notifyFromSocketMessagesArray(context, messages);
        }

        JSONObject data = json.optJSONObject("data");
        if (data != null) {
            JSONArray dataMessages = data.optJSONArray("messages");
            if (dataMessages != null && dataMessages.length() > 0) {
                return notifyFromSocketMessagesArray(context, dataMessages);
            }
            JSONObject normalizedData = normalizeSocketMessagePayload(data, json);
            return notifyFromNormalizedRecord(context, normalizedData, false, false);
        }

        JSONObject normalized = normalizeSocketMessagePayload(json);
        return notifyFromNormalizedRecord(context, normalized, false, false);
    }

    static boolean notifyFromSyncMessagesResponse(Context context, Object payload) {
        Log.d(TAG, "notifyFromSyncMessagesResponse()");
        if (payload instanceof JSONArray) {
            return notifyFromSyncMessagesArray(context, (JSONArray) payload);
        }

        if (!(payload instanceof JSONObject)) {
            Log.w(TAG, "sync_messages_response payload is not a JSONObject or JSONArray");
            return false;
        }

        JSONObject json = (JSONObject) payload;
        JSONArray messages = json.optJSONArray("messages");
        if (messages != null && messages.length() > 0) {
            return notifyFromSyncMessagesArray(context, messages);
        }

        JSONObject data = json.optJSONObject("data");
        if (data != null) {
            JSONArray dataMessages = data.optJSONArray("messages");
            if (dataMessages != null && dataMessages.length() > 0) {
                return notifyFromSyncMessagesArray(context, dataMessages);
            }

            if (data.length() == 0) return false;

            JSONObject normalizedData = normalizeSocketMessagePayload(data, json);
            return notifyFromNormalizedRecord(context, normalizedData, true, true);
        }

        if (json.length() == 0) return false;

        JSONObject normalized = normalizeSocketMessagePayload(json);
        return notifyFromNormalizedRecord(context, normalized, true, true);
    }

    private static JSONObject normalizeSocketMessagePayload(JSONObject payload) {
        return normalizeSocketMessagePayload(payload, null);
    }

    private static JSONObject normalizeSocketMessagePayload(JSONObject payload, @Nullable JSONObject envelope) {
        JSONObject message = payload.optJSONObject("message");
        JSONObject sender = payload.optJSONObject("sender");
        JSONObject room = payload.optJSONObject("room");
        JSONObject normalized = new JSONObject();
        String normalizedMessageId = firstNonEmpty(
            payload.optString("id", null),
            payload.optString("messageId", null),
            payload.optString("message_id", null),
            message != null ? message.optString("id", null) : null,
            message != null ? message.optString("messageId", null) : null,
            message != null ? message.optString("message_id", null) : null,
            envelope != null ? envelope.optString("id", null) : null,
            envelope != null ? envelope.optString("message_id", null) : null
        );

        int roomId = firstPositiveInt(
            message != null ? message.optInt("room_id", message.optInt("roomId", 0)) : 0,
            payload.optInt("room_id", payload.optInt("roomId", 0)),
            room != null ? room.optInt("id", room.optInt("room_id", room.optInt("roomId", 0))) : 0,
            envelope != null ? envelope.optInt("room_id", envelope.optInt("roomId", 0)) : 0,
            envelope != null ? envelope.optInt("room_id_fallback", 0) : 0
        );
        int senderId = firstPositiveInt(
            message != null ? message.optInt("sender_id", message.optInt("senderId", 0)) : 0,
            payload.optInt("sender_id", payload.optInt("senderId", 0)),
            sender != null ? sender.optInt("id", sender.optInt("sender_id", sender.optInt("senderId", 0))) : 0,
            envelope != null ? envelope.optInt("sender_id", envelope.optInt("senderId", 0)) : 0,
            payload.optInt("userId", payload.optInt("user_id", 0))
        );

        putSafe(normalized, "room_id", roomId);
        putSafe(normalized, "sender_id", senderId);
        putSafe(normalized, "id", normalizedMessageId);
        putSafe(normalized, "message_id", normalizedMessageId);
        putSafe(
            normalized,
            "encrypted_message",
            firstNonEmpty(
                payload.optString("encrypted_message", null),
                payload.optString("encryptedMessage", null),
                message != null ? message.optString("encrypted_message", null) : null,
                payload.optString("message", null),
                payload.optString("body", null),
                message != null ? message.optString("ciphertext", null) : null,
                payload.optString("ciphertext", null)
            )
        );
        putSafe(
            normalized,
            "encrypted_username",
            firstNonEmpty(
                payload.optString("encrypted_username", null),
                payload.optString("encryptedUsername", null),
                sender != null ? sender.optString("encrypted_username", null) : null,
                payload.optString("sender_name", null),
                payload.optString("senderName", null),
                sender != null ? sender.optString("username", null) : null,
                payload.optString("username", null)
            )
        );
        putSafe(
            normalized,
            "encrypted_room_name",
            firstNonEmpty(
                payload.optString("encrypted_room_name", null),
                payload.optString("encryptedRoomName", null),
                room != null ? room.optString("encrypted_room_name", null) : null,
                room != null ? room.optString("room_name", null) : null,
                room != null ? room.optString("name", null) : null,
                payload.optString("room_name", null),
                envelope != null ? envelope.optString("encrypted_room_name", null) : null,
                message != null ? message.optString("encrypted_room_name", null) : null
            )
        );
        putSafe(
            normalized,
            "created_at",
            firstNonEmpty(
                payload.optString("created_at", null),
                payload.optString("createdAt", null),
                message != null ? message.optString("created_at", null) : null
            )
        );
        putSafe(
            normalized,
            "avatar_svg",
            firstNonEmpty(
                payload.optString("avatar_svg", null),
                payload.optString("avatarSvg", null),
                sender != null ? sender.optString("avatar_svg", null) : null,
                sender != null ? sender.optString("avatarSvg", null) : null,
                message != null ? message.optString("avatar_svg", null) : null,
                envelope != null ? envelope.optString("avatar_svg", null) : null
            )
        );

        return normalized;
    }

    private static boolean showNotification(
        Context context,
        int roomId,
        int senderId,
        String username,
        String roomName,
        String message,
        String explicitTitle,
        String explicitBody,
        @Nullable String messageId,
        long timestamp,
        boolean isSync,
        boolean deferRender,
        @Nullable String avatarSvg
    ) {
        Log.d(
            TAG,
            "showNotification: avatarSvg present=" + (avatarSvg != null) + " length=" + (avatarSvg != null ? avatarSvg.length() : 0)
        );
        String title;
        if (TextUtils.isEmpty(message) && TextUtils.isEmpty(explicitBody)) {
            Log.d(TAG, "Ignoring notification: No message content available.");
            return false;
        }
        if (shouldSuppressNotificationForRoom(context, roomId)) {
            return false;
        }
        if (!TextUtils.isEmpty(explicitTitle) && !shouldIgnoreGenericPushTitle(explicitTitle)) {
            title = explicitTitle;
        } else if (!TextUtils.isEmpty(username) && !TextUtils.isEmpty(roomName) && isActuallyDecrypted(roomName)) {
            if (username.equalsIgnoreCase(roomName)) {
                title = username;
            } else {
                title = username + " in " + roomName;
            }
        } else if (!TextUtils.isEmpty(username)) {
            title = username;
        } else if (!TextUtils.isEmpty(roomName) && isActuallyDecrypted(roomName)) {
            title = "New message in " + roomName;
        } else {
            title = "New Message";
        }

        String finalBody = !TextUtils.isEmpty(message) ? message : explicitBody;
        if (isSync) {
            boolean hasRealMessageId = !TextUtils.isEmpty(messageId);
            boolean hasUsableBody =
                !TextUtils.isEmpty(finalBody) &&
                !finalBody.trim().isEmpty() &&
                !isGenericOrEmpty(finalBody) &&
                !"New encrypted message".equalsIgnoreCase(finalBody.trim());

            if (!hasRealMessageId || !hasUsableBody) {
                Log.d(TAG, "Ignoring sync notification with no usable message data");
                return false;
            }
        }
        // 4. SECONDARY SAFETY: If finalBody is still empty (or just whitespace), stop.
        if (TextUtils.isEmpty(finalBody) || finalBody.trim().isEmpty()) {
            return false;
        }
        if (deferRender) {
            return NotificationHelper.addMessageToHistory(
                context,
                roomId,
                senderId,
                messageId,
                title,
                finalBody,
                roomName,
                timestamp,
                isSync,
                avatarSvg
            );
        }
        NotificationHelper.showRoomNotification(
            context,
            title,
            finalBody,
            roomId,
            senderId,
            roomName,
            messageId,
            timestamp,
            isSync,
            avatarSvg
        );

        String traceId = !TextUtils.isEmpty(messageId) ? "msg-" + messageId : "android-native-notify-" + roomId + "-" + timestamp;
        JSONObject payload = new JSONObject();
        try {
            payload.put("title", title);
            payload.put("body_preview", finalBody.length() > 120 ? finalBody.substring(0, 120) : finalBody);
            payload.put("is_sync", isSync);
            payload.put("defer_render", deferRender);
        } catch (Exception ignored) {}
        MessageFlowLogger.log(
            context,
            traceId,
            messageId,
            roomId > 0 ? roomId : null,
            senderId > 0 ? senderId : null,
            "android_notification_displayed",
            "Android native layer displayed message notification",
            "notification",
            "success",
            payload,
            null
        );
        return true;
    }

    private static boolean notifyFromSocketMessagesArray(Context context, JSONArray messages) {
        boolean any = false;
        for (int i = 0; i < messages.length(); i++) {
            JSONObject item = messages.optJSONObject(i);
            if (item == null) continue;
            JSONObject normalized = normalizeSocketMessagePayload(item);
            if (notifyFromNormalizedRecord(context, normalized, false, false)) any = true;
        }
        return any;
    }

    private static boolean notifyFromSyncMessagesArray(Context context, JSONArray messages) {
        boolean any = false;
        Set<Integer> processedRooms = new HashSet<>();
        Set<Integer> roomsWithNewMessages = new HashSet<>();
        Map<Integer, String> lastRoomNames = new HashMap<>();

        for (int i = 0; i < messages.length(); i++) {
            JSONObject item = messages.optJSONObject(i);
            if (item == null) continue;

            JSONObject normalized = normalizeSocketMessagePayload(item);
            int roomId = normalized.optInt("room_id", 0);

            if (roomId > 0 && !processedRooms.contains(roomId)) {
                boolean notifActive = NotificationHelper.isNotificationActive(context, roomId);
                if (!notifActive) {
                    NotificationHelper.clearRoomHistory(context, roomId, false);
                }
                processedRooms.add(roomId);
            }

            if (notifyFromNormalizedRecord(context, normalized, false, false, true)) {
                any = true;
                if (roomId > 0) {
                    roomsWithNewMessages.add(roomId);
                }

                String roomName = decryptRoomName(context, roomId, normalized.optString("encrypted_room_name", null));
                if (isActuallyDecrypted(roomName)) {
                    lastRoomNames.put(roomId, roomName);
                }
            }
        }

        for (int roomId : roomsWithNewMessages) {
            String roomName = lastRoomNames.get(roomId);
            String title = (roomName != null) ? roomName : "New Message";
            NotificationHelper.triggerNotificationUpdate(context, roomId, title);
        }

        return any;
    }

    private static boolean notifyFromNormalizedRecord(Context context, JSONObject normalized, boolean clearHistoryFirst, boolean isSync) {
        return notifyFromNormalizedRecord(context, normalized, clearHistoryFirst, isSync, false);
    }

    private static boolean notifyFromNormalizedRecord(
        Context context,
        JSONObject normalized,
        boolean clearHistoryFirst,
        boolean isSync,
        boolean deferRender
    ) {
        int roomId = normalized.optInt("room_id", 0);
        int senderId = normalized.optInt("sender_id", 0);
        String messageId = firstNonEmpty(normalized.optString("id", null), normalized.optString("message_id", null));
        long timestamp = parseTimestamp(normalized.optString("created_at", null));

        if (clearHistoryFirst && roomId > 0) {
            // Clear memory but don't cancel notification during sync rebuild
            NotificationHelper.clearRoomHistory(context, roomId, false);
        }

        String rawRoomName = firstNonEmpty(
            normalized.optString("encrypted_room_name", null),
            normalized.optString("room_name", null),
            normalized.optString("encryptedRoomName", null)
        );
        String roomName = decryptRoomName(context, roomId, rawRoomName);

        if (roomId > 0) {
            if (isActuallyDecrypted(roomName)) {
                NotificationHelper.setRoomName(context, roomId, roomName);
            } else {
                String cached = NotificationHelper.getRoomName(roomId);
                if (cached != null) roomName = cached;
            }
        }

        String username = decryptUserName(
            context,
            senderId,
            firstNonEmpty(
                normalized.optString("encrypted_username", null),
                normalized.optString("sender_name", null),
                normalized.optString("username", null)
            )
        );
        String message = decryptRoomMessage(
            context,
            roomId,
            firstNonEmpty(
                normalized.optString("encrypted_message", null),
                normalized.optString("message", null),
                normalized.optString("body", null),
                normalized.optString("ciphertext", null)
            )
        );

        if (isGenericOrEmpty(message)) {
            if (!TextUtils.isEmpty(roomName) && isActuallyDecrypted(roomName)) {
                message = "New message in " + roomName;
            }
        }

        return showNotification(
            context,
            roomId,
            senderId,
            username,
            roomName,
            message,
            normalized.optString("title", null),
            normalized.optString("body", null),
            messageId,
            timestamp,
            isSync,
            deferRender,
            normalized.optString("avatar_svg", null)
        );
    }

    private static JSONObject normalizeIncomingMessageRecord(JSONObject item) {
        if (item == null) return new JSONObject();
        if (item.has("message") || item.has("sender") || item.has("room")) return normalizeSocketMessagePayload(item);
        return item;
    }

    private static boolean isActuallyDecrypted(String value) {
        if (TextUtils.isEmpty(value)) return false;
        return !looksLikeEncryptedJson(value);
    }

    private static boolean shouldIgnoreGenericPushTitle(String title) {
        if (TextUtils.isEmpty(title)) return true;
        String normalized = title.trim().toLowerCase();
        return (
            "new message".equals(normalized) ||
            "new messages".equals(normalized) ||
            "message".equals(normalized) ||
            "messages".equals(normalized)
        );
    }

    private static String decryptRoomName(Context context, int roomId, String encryptedRoomName) {
        if (roomId <= 0 || TextUtils.isEmpty(encryptedRoomName) || !looksLikeEncryptedJson(encryptedRoomName)) return encryptedRoomName;
        try {
            NativeCrypto crypto = new NativeCrypto(context);
            JSObject decrypted = crypto.decryptRoomData(roomId, encryptedRoomName);
            return decrypted.optString("text", encryptedRoomName);
        } catch (Exception e) {
            Log.d(TAG, "decryptRoomName: failed for roomId=" + roomId + ", error=" + e.getMessage());
            return encryptedRoomName;
        }
    }

    private static String decryptUserName(Context context, int senderId, String encryptedUserNameOrPlain) {
        if (TextUtils.isEmpty(encryptedUserNameOrPlain)) return null;
        if (senderId <= 0 || !looksLikeEncryptedJson(encryptedUserNameOrPlain)) return encryptedUserNameOrPlain;
        try {
            NativeCrypto crypto = new NativeCrypto(context);
            JSObject decrypted = crypto.decryptUserData(senderId, encryptedUserNameOrPlain);
            return decrypted.optString("text", encryptedUserNameOrPlain);
        } catch (Exception e) {
            Log.d(TAG, "decryptUserName: failed for senderId=" + senderId + ", error=" + e.getMessage());
            return encryptedUserNameOrPlain;
        }
    }

    private static String decryptRoomMessage(Context context, int roomId, String encryptedMessageOrPlain) {
        if (TextUtils.isEmpty(encryptedMessageOrPlain)) return null;
        if (roomId <= 0 || !looksLikeEncryptedJson(encryptedMessageOrPlain)) {
            if (looksLikeCiphertextBlob(encryptedMessageOrPlain)) return "New encrypted message";
            return encryptedMessageOrPlain;
        }
        try {
            NativeCrypto crypto = new NativeCrypto(context);
            JSObject decrypted = crypto.decryptRoomData(roomId, encryptedMessageOrPlain);
            return decrypted.optString("text", encryptedMessageOrPlain);
        } catch (Exception e) {
            Log.d(TAG, "decryptRoomMessage: failed for roomId=" + roomId + ", error=" + e.getMessage());
            return "New encrypted message";
        }
    }

    private static boolean looksLikeEncryptedJson(String value) {
        if (value == null) return false;
        String v = value.trim();
        return (
            v.startsWith("{") &&
            (v.contains("encryptedData") || v.contains("encryptedMessage") || v.contains("ciphertext")) &&
            (v.contains("iv") || v.contains("nonce"))
        );
    }

    private static boolean looksLikeCiphertextBlob(String value) {
        if (TextUtils.isEmpty(value)) return false;
        return value.length() > 80 && value.matches("^[A-Za-z0-9+/=._-]+$");
    }

    private static boolean isGenericOrEmpty(String message) {
        if (TextUtils.isEmpty(message)) return true;
        String m = message.toLowerCase();
        return m.contains("you have") && m.contains("new message");
    }

    private static int parseInt(String value, int fallback) {
        if (TextUtils.isEmpty(value)) return fallback;
        try {
            return Integer.parseInt(value);
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    private static long parseTimestamp(String value) {
        if (TextUtils.isEmpty(value) || "null".equalsIgnoreCase(value)) return 0;
        try {
            String[] formats = {
                "yyyy-MM-dd HH:mm:ss",
                "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
                "yyyy-MM-dd'T'HH:mm:ss'Z'",
                "yyyy-MM-dd'T'HH:mm:ss"
            };
            for (String fmt : formats) {
                try {
                    SimpleDateFormat sdf = new SimpleDateFormat(fmt, Locale.US);
                    if (fmt.endsWith("'Z'")) sdf.setTimeZone(TimeZone.getTimeZone("UTC"));
                    return sdf.parse(value).getTime();
                } catch (Exception ignored) {}
            }
            return Long.parseLong(value);
        } catch (Exception e) {
            return 0;
        }
    }

    private static int firstPositiveInt(int... values) {
        for (int value : values) if (value > 0) return value;
        return 0;
    }

    private static String firstNonEmpty(String... values) {
        for (String value : values) if (!TextUtils.isEmpty(value) && !"null".equalsIgnoreCase(value)) return value;
        return null;
    }

    private static void putSafe(JSONObject object, String key, Object value) {
        try {
            object.put(key, value);
        } catch (Exception ignored) {}
    }

    private static boolean shouldSuppressNotificationForRoom(Context context, int roomId) {
        if (roomId <= 0) return false;

        SharedPreferences prefs = context.getSharedPreferences("safe_storage", Context.MODE_PRIVATE);

        String mutedRaw = prefs.getString("room_notification_muted:" + roomId, null);
        boolean muted = "1".equals(mutedRaw) || "true".equalsIgnoreCase(mutedRaw);
        if (muted) {
            Log.d(TAG, "Suppressing notification: room is muted. roomId=" + roomId + " room_notification_muted=" + mutedRaw);
            return true;
        }

        // Legacy key compatibility: 1 means enabled; anything else means disabled.
        String legacyEnabledRaw = prefs.getString("push_notifications_room_" + roomId, null);
        if (!TextUtils.isEmpty(legacyEnabledRaw) && !"1".equals(legacyEnabledRaw)) {
            Log.d(
                TAG,
                "Suppressing notification: legacy room notifications disabled. roomId=" +
                    roomId +
                    " push_notifications_room_=" +
                    legacyEnabledRaw
            );
            return true;
        }

        if (!isAppInForeground(context)) {
            Log.d(TAG, "App not foreground; skipping active room suppression check for roomId=" + roomId);
            return false;
        }

        String activeRoomRaw = prefs.getString("active_room_id", null);
        int activeRoomId = parseInt(activeRoomRaw, 0);
        if (activeRoomId > 0 && activeRoomId == roomId) {
            Log.d(TAG, "Suppressing notification: room is active in foreground. roomId=" + roomId + " active_room_id=" + activeRoomRaw);
            return true;
        }

        return false;
    }

    private static boolean isAppInForeground(Context context) {
        ActivityManager activityManager = (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);
        if (activityManager == null) return false;

        List<ActivityManager.RunningAppProcessInfo> processes = activityManager.getRunningAppProcesses();
        if (processes == null) return false;

        String packageName = context.getPackageName();
        for (ActivityManager.RunningAppProcessInfo process : processes) {
            if (process == null) continue;
            if (!packageName.equals(process.processName)) continue;

            int importance = process.importance;
            return (
                importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND ||
                importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE
            );
        }

        return false;
    }
}
