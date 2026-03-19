package com.codecraft_studio.messenger.notifications;

import android.content.Context;
import android.util.Log;
import java.util.Map;
import org.json.JSONObject;

/**
 * Handles incoming push/socket payloads, decrypts them, and triggers notifications.
 */
public class EncryptedMessageNotifier {

    private static final String TAG = "MessageNotifier";

    public static boolean notifyFromPushData(Context context, Map<String, String> data) {
        if (data == null || data.isEmpty()) return false;
        try {
            int roomId = Integer.parseInt(data.get("roomId") != null ? data.get("roomId") : data.get("room_id"));
            String senderName = data.get("senderName") != null ? data.get("senderName") : data.get("title");
            String body = data.get("body") != null ? data.get("body") : data.get("message");
            String messageId = data.get("messageId") != null ? data.get("messageId") : data.get("id");
            long timestamp = System.currentTimeMillis();

            NotificationHelper.showRoomNotification(context, senderName, body, roomId, messageId, timestamp);
            return true;
        } catch (Exception e) {
            Log.e(TAG, "Error processing push data", e);
        }
        return false;
    }

    public static boolean notifyFromSocketPayload(Context context, Object payload) {
        if (!(payload instanceof JSONObject)) return false;
        JSONObject obj = (JSONObject) payload;
        try {
            int roomId = obj.optInt("room_id", obj.optInt("roomId"));
            if (roomId <= 0) return false;

            String encryptedMsg = obj.optString("encrypted_message", obj.optString("encryptedMessage"));
            String encryptedUser = obj.optString("encrypted_username", obj.optString("encryptedUsername"));
            String encryptedRoom = obj.optString("encrypted_room_name", obj.optString("encryptedRoomName"));

            String senderName = encryptedUser.isEmpty()
                ? "New Message"
                : NativeCrypto.decryptUserData(obj.optInt("sender_id"), encryptedUser).text;
            String messageBody = encryptedMsg.isEmpty() ? "New encrypted message" : NativeCrypto.decryptRoomData(roomId, encryptedMsg).text;
            String roomName = encryptedRoom.isEmpty() ? null : NativeCrypto.decryptRoomData(roomId, encryptedRoom).text;

            String messageId = obj.optString("id", obj.optString("messageId"));
            long timestamp = obj.optLong("timestamp", System.currentTimeMillis());

            NotificationHelper.showRoomNotification(context, senderName, messageBody, roomId, roomName, messageId, timestamp, false);
            return true;
        } catch (Exception e) {
            Log.e(TAG, "Error processing socket payload", e);
        }
        return false;
    }

    public static boolean notifyFromSyncMessagesResponse(Context context, Object arg) {
        // For sync response, we just treat each message as a socket payload.
        return notifyFromSocketPayload(context, arg);
    }

    public static void notifyFromUnreadApiRecord(Context context, JSONObject item) {
        notifyFromSocketPayload(context, item);
    }
}
