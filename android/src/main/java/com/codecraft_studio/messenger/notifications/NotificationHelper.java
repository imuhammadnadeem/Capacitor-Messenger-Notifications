package com.codecraft_studio.messenger.notifications;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Build;
import android.service.notification.StatusBarNotification;
import android.text.TextUtils;
import android.util.Log;
import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;
import androidx.core.app.Person;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Iterator;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

final class NotificationHelper {

    private static final String TAG = "NotificationHelper";
    private static final String CHANNEL_ID = "chat_messages";
    private static final String CHANNEL_NAME = "Chat Messages";
    private static final String GROUP_KEY_PREFIX = "com.codecraft_studio.messenger.notifications.ROOM_GROUP.";
    private static final int GENERIC_NOTIFICATION_ID = 900000;
    private static final String PREFS_NAME = "notification_history";
    private static final String KEY_RECENT_IDS = "recent_message_ids";
    private static final String KEY_DISMISSED_IDS = "dismissed_message_ids";
    private static final String KEY_DISMISSED_UNTIL_BY_ROOM = "dismissed_until_by_room";
    private static final String KEY_ROOM_NAMES = "room_names_by_id";
    private static final String KEY_USER_NAMES = "user_names_by_id";
    private static final int MAX_PERSISTENT_IDS = 300;
    private static final int MAX_DISMISSED_IDS = 500;
    static final String EXTRA_ROOM_ID = "extra_room_id";

    // Static roomId that launched the app
    private static Integer pendingRoomId = null;

    private static final Map<Integer, List<MessageRecord>> roomMessages = new ConcurrentHashMap<>();
    private static final Map<Integer, String> roomNamesById = new ConcurrentHashMap<>();
    private static final Map<Integer, String> userNamesById = new ConcurrentHashMap<>();
    private static final int MAX_MESSAGES_PER_ROOM = 50;

    private static final Set<String> recentMessageIds = Collections.synchronizedSet(new LinkedHashSet<>());
    private static final Set<String> dismissedMessageIds = Collections.synchronizedSet(new LinkedHashSet<>());
    private static final Map<Integer, Long> dismissedUntilByRoom = new ConcurrentHashMap<>();

    private static volatile long serverTimeOffset = 0L;
    private static final Object offsetLock = new Object();

    static synchronized Integer getPendingRoomId() {
        return pendingRoomId;
    }

    static synchronized void setPendingRoomId(Integer roomId) {
        pendingRoomId = roomId;
    }

    static synchronized void consumePendingRoomId() {
        pendingRoomId = null;
    }

    private static String roomGroupKey(int roomId) {
        return GROUP_KEY_PREFIX + roomId;
    }

    private static int roomSummaryId(int roomId) {
        return roomId + 500000;
    }

    static class MessageRecord {

        @Nullable
        final String id;

        final String sender;
        final String text;
        final long timestamp;
        final boolean hasServerTimestamp;
        final int quality;

        MessageRecord(@Nullable String id, String sender, String text, long timestamp, boolean hasServerTimestamp) {
            this.id = id;
            this.sender = sender;
            this.text = text;
            this.timestamp = timestamp;
            this.hasServerTimestamp = hasServerTimestamp;
            this.quality = calculateQuality(id, sender);
        }

        private static int calculateQuality(String id, String sender) {
            int q = 0;
            if (id != null && !id.isEmpty() && !"null".equalsIgnoreCase(id)) q += 10;
            if (!isGenericTitle(sender)) q += 5;
            return q;
        }
    }

    private NotificationHelper() {}

    static void clearRoomHistory(Context context, int roomId, boolean cancelNotification) {
        roomMessages.remove(roomId);
        if (cancelNotification) {
            NotificationManager manager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
            if (manager != null) {
                manager.cancel(resolveNotificationId(roomId));
                manager.cancel(roomSummaryId(roomId));
            }
        }
    }

    static void showRoomNotification(Context context, String title, String body, int roomId, @Nullable String messageId, long timestamp) {
        showRoomNotification(context, title, body, roomId, null, messageId, timestamp, false);
    }

    static void showRoomNotification(
        Context context,
        String title,
        String body,
        int roomId,
        @Nullable String roomName,
        @Nullable String messageId,
        long timestamp,
        boolean isSync
    ) {
        if (addMessageToHistory(context, roomId, 0, messageId, title, body, roomName, timestamp, isSync)) {
            triggerNotificationUpdate(context, roomId, title);
        }
    }

    static boolean addMessageToHistory(
        Context context,
        int roomId,
        int senderId,
        @Nullable String messageId,
        String title,
        String body,
        @Nullable String roomName,
        long timestamp,
        boolean isSync
    ) {
        if (TextUtils.isEmpty(body)) return false;
        if (roomId <= 0) return false;

        loadNamesIfEmpty(context);
        if (roomId > 0 && !TextUtils.isEmpty(roomName) && !isGenericTitle(roomName)) {
            setRoomName(context, roomId, roomName);
        }

        boolean hasServerTimestamp = timestamp > 0;
        long useTimestamp;
        if (timestamp > 0) {
            useTimestamp = timestamp;
            synchronized (offsetLock) {
                serverTimeOffset = timestamp - System.currentTimeMillis();
            }
        } else {
            synchronized (offsetLock) {
                useTimestamp = System.currentTimeMillis() + serverTimeOffset;
            }
        }

        String senderName = title;
        if (title != null && title.contains(" in ")) {
            senderName = title.split(" in ")[0];
        }

        if (isGenericTitle(senderName)) {
            if (senderId > 0) {
                String cachedUser = userNamesById.get(senderId);
                if (!isGenericTitle(cachedUser)) {
                    senderName = cachedUser;
                }
            }

            if (isGenericTitle(senderName)) {
                List<MessageRecord> history = roomMessages.get(roomId);
                if (history != null) {
                    synchronized (history) {
                        for (int i = history.size() - 1; i >= 0; i--) {
                            if (!isGenericTitle(history.get(i).sender)) {
                                senderName = history.get(i).sender;
                                break;
                            }
                        }
                    }
                }
            }

            if (isGenericTitle(senderName) && roomId > 0) {
                String cachedRoomName = roomNamesById.get(roomId);
                if (!isGenericTitle(cachedRoomName)) {
                    senderName = cachedRoomName;
                }
            }
        }

        if (senderId > 0 && !isGenericTitle(senderName)) {
            setUserName(context, senderId, senderName);
        }

        if (senderName == null || isGenericTitle(senderName)) {
            senderName = "New Message";
        }

        String normText = body.trim();
        boolean hasId = (messageId != null && !messageId.isEmpty() && !"null".equalsIgnoreCase(messageId));

        List<MessageRecord> history = roomMessages.get(roomId);
        if (history == null) {
            history = Collections.synchronizedList(new ArrayList<>());
            roomMessages.put(roomId, history);
        }

        synchronized (history) {
            if (hasId && !isSync) {
                loadRecentIdsIfEmpty(context);
                if (recentMessageIds.contains(messageId)) {
                    return false;
                }
            }

            if (hasId) {
                loadDismissedIdsIfEmpty(context);
                if (dismissedMessageIds.contains(messageId)) {
                    return false;
                }
            }

            if (roomId > 0 && hasServerTimestamp) {
                loadDismissedCutoffByRoomIfEmpty(context);
                Long value = dismissedUntilByRoom.get(roomId);
                long dismissedUntil = value == null ? 0L : value;
                if (dismissedUntil > 0L && timestamp <= dismissedUntil) {
                    return false;
                }
            }

            MessageRecord newRec = new MessageRecord(messageId, senderName, body, useTimestamp, hasServerTimestamp);

            for (int i = 0; i < history.size(); i++) {
                MessageRecord rec = history.get(i);

                if (hasId && messageId.equals(rec.id)) {
                    if (newRec.quality > rec.quality) {
                        history.remove(i);
                        break;
                    }
                    return false;
                }

                if (hasId && rec.id != null && !rec.id.isEmpty() && !"null".equalsIgnoreCase(rec.id) && !messageId.equals(rec.id)) {
                    continue;
                }

                if (
                    normText.equalsIgnoreCase(rec.text.trim()) &&
                    senderName.equals(rec.sender) &&
                    Math.abs(useTimestamp - rec.timestamp) < 300000
                ) {
                    if ((hasId && (rec.id == null || rec.id.isEmpty())) || newRec.quality > rec.quality) {
                        history.remove(i);
                        break;
                    }
                    return false;
                }
            }

            if (hasId) addAndPersistMessageId(context, messageId);
            history.add(newRec);
            if (history.size() > 1) {
                Collections.sort(history, (a, b) -> Long.compare(a.timestamp, b.timestamp));
            }
            if (history.size() > MAX_MESSAGES_PER_ROOM) history.remove(0);
        }

        FcmFetchManager.markNotificationShown(roomId);
        return true;
    }

    static void triggerNotificationUpdate(Context context, int roomId, String title) {
        NotificationManager manager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
        if (manager == null) return;

        ensureChannel(manager);
        loadNamesIfEmpty(context);

        Intent intent = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
        if (intent != null) {
            intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
            if (roomId > 0) intent.putExtra("roomId", roomId);
        }

        PendingIntent pendingIntent = PendingIntent.getActivity(
            context,
            resolveRequestCode(roomId),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );

        Intent dismissIntent = new Intent(context, NotificationDismissReceiver.class);
        dismissIntent.putExtra(EXTRA_ROOM_ID, roomId);
        PendingIntent dismissPendingIntent = PendingIntent.getBroadcast(
            context,
            resolveRequestCode(roomId) + 1000000,
            dismissIntent,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );

        String convTitle = (title != null && title.contains(" in ")) ? title.split(" in ")[1] : title;
        if (roomId > 0 && isGenericTitle(convTitle)) {
            String cachedRoomName = roomNamesById.get(roomId);
            if (!TextUtils.isEmpty(cachedRoomName)) {
                convTitle = cachedRoomName;
            }
        }
        if (isGenericTitle(convTitle)) {
            convTitle = "Chat";
        }

        NotificationCompat.Builder builder = new NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(context.getApplicationInfo().icon)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setVibrate(new long[] { 0, 250, 250, 250 })
            .setAutoCancel(true)
            .setGroup(roomGroupKey(roomId))
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
            .setOnlyAlertOnce(true)
            .setContentIntent(pendingIntent)
            .setDeleteIntent(dismissPendingIntent);

        List<MessageRecord> history = roomMessages.get(roomId);
        if (history != null && !history.isEmpty()) {
            Person user = new Person.Builder().setName("Me").build();

            NotificationCompat.MessagingStyle style = new NotificationCompat.MessagingStyle(user).setConversationTitle(convTitle);

            MessageRecord lastMsg = null;
            synchronized (history) {
                for (MessageRecord msg : history) {
                    Person sender = new Person.Builder().setName(nonEmptyOrDefault(msg.sender, "User")).build();
                    style.addMessage(msg.text, msg.timestamp, sender);
                    lastMsg = msg;
                }
            }
            builder.setStyle(style);
            if (lastMsg != null) {
                builder
                    .setContentTitle(nonEmptyOrDefault(lastMsg.sender, "New Message"))
                    .setContentText(lastMsg.text)
                    .setWhen(lastMsg.timestamp);
            }
        } else {
            builder.setContentTitle(nonEmptyOrDefault(title, "New Message")).setContentText("You have new messages");
        }

        manager.notify(resolveNotificationId(roomId), builder.build());
        postRoomSummary(context, manager, roomId, convTitle);
    }

    private static void postRoomSummary(Context context, NotificationManager manager, int roomId, String convTitle) {
        List<MessageRecord> history = roomMessages.get(roomId);
        int msgCount = history != null ? history.size() : 0;

        if (msgCount <= 1) {
            manager.cancel(roomSummaryId(roomId));
            return;
        }

        String summaryText = msgCount + " new messages";

        Notification summaryNotification = new NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle(convTitle)
            .setContentText(summaryText)
            .setSmallIcon(context.getApplicationInfo().icon)
            .setStyle(new NotificationCompat.InboxStyle().setSummaryText(convTitle))
            .setGroup(roomGroupKey(roomId))
            .setGroupSummary(true)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
            .setSilent(true)
            .setAutoCancel(true)
            .build();

        manager.notify(roomSummaryId(roomId), summaryNotification);
    }

    static void onNotificationDismissed(Context context, int roomId) {
        List<MessageRecord> history = roomMessages.get(roomId);
        long latestServerTimestamp = 0L;
        if (history != null) {
            synchronized (history) {
                for (MessageRecord record : history) {
                    if (!TextUtils.isEmpty(record.id) && !"null".equalsIgnoreCase(record.id)) {
                        addAndPersistDismissedMessageId(context, record.id);
                    }
                    if (record.hasServerTimestamp && record.timestamp > latestServerTimestamp) {
                        latestServerTimestamp = record.timestamp;
                    }
                }
            }
        }
        if (roomId > 0 && latestServerTimestamp > 0L) {
            setAndPersistDismissedUntilForRoom(context, roomId, latestServerTimestamp);
        }
        roomMessages.remove(roomId);
        NotificationManager manager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
        if (manager != null) {
            manager.cancel(roomSummaryId(roomId));
        }
    }

    private static boolean isGenericTitle(@Nullable String title) {
        if (TextUtils.isEmpty(title)) return true;
        String t = title.trim().toLowerCase();
        return "new message".equals(t) || "new messages".equals(t) || "message".equals(t);
    }

    private static void loadRecentIdsIfEmpty(Context context) {
        if (!recentMessageIds.isEmpty()) return;
        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        String json = prefs.getString(KEY_RECENT_IDS, null);
        if (json != null) {
            try {
                JSONArray array = new JSONArray(json);
                synchronized (recentMessageIds) {
                    for (int i = 0; i < array.length(); i++) {
                        recentMessageIds.add(array.getString(i));
                    }
                }
            } catch (JSONException ignored) {}
        }
    }

    private static void loadDismissedIdsIfEmpty(Context context) {
        if (!dismissedMessageIds.isEmpty()) return;
        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        String json = prefs.getString(KEY_DISMISSED_IDS, null);
        if (json != null) {
            try {
                JSONArray array = new JSONArray(json);
                synchronized (dismissedMessageIds) {
                    for (int i = 0; i < array.length(); i++) {
                        dismissedMessageIds.add(array.getString(i));
                    }
                }
            } catch (JSONException ignored) {}
        }
    }

    private static void loadDismissedCutoffByRoomIfEmpty(Context context) {
        if (!dismissedUntilByRoom.isEmpty()) return;
        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        String json = prefs.getString(KEY_DISMISSED_UNTIL_BY_ROOM, null);
        if (TextUtils.isEmpty(json)) return;
        try {
            JSONObject object = new JSONObject(json);
            Iterator<String> keys = object.keys();
            while (keys.hasNext()) {
                String roomKey = keys.next();
                try {
                    int roomId = Integer.parseInt(roomKey);
                    long dismissedUntil = object.optLong(roomKey, 0L);
                    if (roomId > 0 && dismissedUntil > 0L) {
                        dismissedUntilByRoom.put(roomId, dismissedUntil);
                    }
                } catch (NumberFormatException ignored) {}
            }
        } catch (JSONException ignored) {}
    }

    private static void loadNamesIfEmpty(Context context) {
        if (!roomNamesById.isEmpty() || !userNamesById.isEmpty()) return;
        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        loadMapFromPrefs(prefs, KEY_ROOM_NAMES, roomNamesById);
        loadMapFromPrefs(prefs, KEY_USER_NAMES, userNamesById);
    }

    private static void loadMapFromPrefs(SharedPreferences prefs, String key, Map<Integer, String> targetMap) {
        String json = prefs.getString(key, null);
        if (TextUtils.isEmpty(json)) return;
        try {
            JSONObject object = new JSONObject(json);
            Iterator<String> keys = object.keys();
            while (keys.hasNext()) {
                String strId = keys.next();
                try {
                    int id = Integer.parseInt(strId);
                    String name = object.getString(strId);
                    if (id > 0 && !TextUtils.isEmpty(name)) targetMap.put(id, name);
                } catch (NumberFormatException ignored) {}
            }
        } catch (JSONException ignored) {}
    }

    private static void persistMapToPrefs(Context context, String key, Map<Integer, String> map) {
        JSONObject object = new JSONObject();
        for (Map.Entry<Integer, String> entry : map.entrySet()) {
            try {
                object.put(String.valueOf(entry.getKey()), entry.getValue());
            } catch (JSONException ignored) {}
        }
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit().putString(key, object.toString()).apply();
    }

    private static void addAndPersistMessageId(Context context, String messageId) {
        synchronized (recentMessageIds) {
            recentMessageIds.remove(messageId);
            recentMessageIds.add(messageId);
            if (recentMessageIds.size() > MAX_PERSISTENT_IDS) {
                Iterator<String> it = recentMessageIds.iterator();
                int toRemove = recentMessageIds.size() - MAX_PERSISTENT_IDS;
                while (toRemove > 0 && it.hasNext()) {
                    it.next();
                    it.remove();
                    toRemove--;
                }
            }
        }
        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        JSONArray array = new JSONArray();
        synchronized (recentMessageIds) {
            for (String id : recentMessageIds) array.put(id);
        }
        prefs.edit().putString(KEY_RECENT_IDS, array.toString()).apply();
    }

    private static void addAndPersistDismissedMessageId(Context context, String messageId) {
        synchronized (dismissedMessageIds) {
            dismissedMessageIds.remove(messageId);
            dismissedMessageIds.add(messageId);
            if (dismissedMessageIds.size() > MAX_DISMISSED_IDS) {
                Iterator<String> it = dismissedMessageIds.iterator();
                int toRemove = dismissedMessageIds.size() - MAX_DISMISSED_IDS;
                while (toRemove > 0 && it.hasNext()) {
                    it.next();
                    it.remove();
                    toRemove--;
                }
            }
        }
        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        JSONArray array = new JSONArray();
        synchronized (dismissedMessageIds) {
            for (String id : dismissedMessageIds) array.put(id);
        }
        prefs.edit().putString(KEY_DISMISSED_IDS, array.toString()).apply();
    }

    private static void setAndPersistDismissedUntilForRoom(Context context, int roomId, long dismissedUntilTs) {
        if (roomId <= 0 || dismissedUntilTs <= 0L) return;
        loadDismissedCutoffByRoomIfEmpty(context);
        Long existing = dismissedUntilByRoom.get(roomId);
        if (existing != null && existing >= dismissedUntilTs) return;
        dismissedUntilByRoom.put(roomId, dismissedUntilTs);
        persistDismissedCutoffByRoom(context);
    }

    private static void persistDismissedCutoffByRoom(Context context) {
        JSONObject object = new JSONObject();
        for (Map.Entry<Integer, Long> entry : dismissedUntilByRoom.entrySet()) {
            if (entry.getKey() == null || entry.getValue() == null || entry.getKey() <= 0 || entry.getValue() <= 0L) continue;
            try {
                object.put(String.valueOf(entry.getKey()), entry.getValue());
            } catch (JSONException ignored) {}
        }
        context
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_DISMISSED_UNTIL_BY_ROOM, object.toString())
            .apply();
    }

    private static void ensureChannel(NotificationManager manager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        NotificationChannel channel = manager.getNotificationChannel(CHANNEL_ID);
        if (channel == null) {
            channel = new NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_HIGH);
            channel.setDescription("Notifications for chat messages");
            channel.enableVibration(true);
            manager.createNotificationChannel(channel);
        }
    }

    private static int resolveNotificationId(int roomId) {
        return roomId > 0 ? roomId : GENERIC_NOTIFICATION_ID;
    }

    private static int resolveRequestCode(int roomId) {
        return roomId > 0 ? roomId : GENERIC_NOTIFICATION_ID;
    }

    private static String nonEmptyOrDefault(@Nullable String value, String fallback) {
        return value == null || value.trim().isEmpty() ? fallback : value;
    }

    static void setRoomName(Context context, int roomId, @Nullable String roomName) {
        if (roomId <= 0 || TextUtils.isEmpty(roomName) || isGenericTitle(roomName)) return;
        roomNamesById.put(roomId, roomName);
        persistMapToPrefs(context, KEY_ROOM_NAMES, roomNamesById);
    }

    static void setUserName(Context context, int userId, @Nullable String userName) {
        if (userId <= 0 || TextUtils.isEmpty(userName) || isGenericTitle(userName)) return;
        userNamesById.put(userId, userName);
        persistMapToPrefs(context, KEY_USER_NAMES, userNamesById);
    }
}
