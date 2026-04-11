package com.codecraft_studio.messenger.notifications;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Rect;
import android.os.Build;
import android.service.notification.StatusBarNotification;
import android.text.TextUtils;
import android.util.Log;
import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;
import androidx.core.app.Person;
import androidx.core.content.pm.ShortcutInfoCompat;
import androidx.core.content.pm.ShortcutManagerCompat;
import androidx.core.graphics.drawable.IconCompat;
import com.caverock.androidsvg.SVG;
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

    private static String groupKeyAllRooms(Context context) {
        return context.getPackageName() + ".ALL_ROOMS";
    }

    private static final int GENERIC_NOTIFICATION_ID = 900000;
    private static final int GLOBAL_SUMMARY_NOTIFICATION_ID = 900001;
    private static final String PREFS_NAME = "notification_history";
    private static final String KEY_RECENT_IDS = "recent_message_ids";
    private static final String KEY_DISMISSED_IDS = "dismissed_message_ids";
    private static final String KEY_DISMISSED_UNTIL_BY_ROOM = "dismissed_until_by_room";
    private static final String KEY_ROOM_NAMES = "room_names_by_id";
    private static final String KEY_USER_NAMES = "user_names_by_id";
    private static final int MAX_PERSISTENT_IDS = 300;
    private static final int MAX_DISMISSED_IDS = 500;
    static final String EXTRA_ROOM_ID = "extra_room_id";

    // In-memory message history for MessagingStyle.
    private static final Map<Integer, List<MessageRecord>> roomMessages = new ConcurrentHashMap<>();

    // Persisted name caches
    private static final Map<Integer, String> roomNamesById = new ConcurrentHashMap<>();
    private static final Map<Integer, String> userNamesById = new ConcurrentHashMap<>();

    private static final int MAX_MESSAGES_PER_ROOM = 50;

    // Persistent de-duplication cache. Using LinkedHashSet to maintain insertion order for LRU eviction.
    private static final Set<String> recentMessageIds = Collections.synchronizedSet(new LinkedHashSet<>());
    private static final Set<String> dismissedMessageIds = Collections.synchronizedSet(new LinkedHashSet<>());
    private static final Map<Integer, Long> dismissedUntilByRoom = new ConcurrentHashMap<>();

    // Track server clock skew to align local events with server timestamps.
    private static volatile long serverTimeOffset = 0L;
    private static final Object offsetLock = new Object();

    private static volatile Integer pendingRoomId = null;

    static void setPendingRoomId(int roomId) {
        pendingRoomId = roomId > 0 ? roomId : null;
    }

    static Integer getPendingRoomId() {
        return pendingRoomId;
    }

    static void consumePendingRoomId() {
        pendingRoomId = null;
    }

    static class MessageRecord {

        @Nullable
        final String id;

        final String sender; // display name shown in the notification
        final String senderKey; // identity key for deduplication (senderId if known, else display name)

        @Nullable
        final String avatarSvg;

        final String text;
        final long timestamp;
        final boolean hasServerTimestamp;
        final int quality;

        MessageRecord(
            @Nullable String id,
            String sender,
            String senderKey,
            String text,
            long timestamp,
            boolean hasServerTimestamp,
            @Nullable String avatarSvg
        ) {
            this.id = id;
            this.sender = sender;
            this.senderKey = senderKey;
            this.avatarSvg = avatarSvg;
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

    /**
     * Clears in-memory history. If cancelNotification is true, also removes it from the status bar.
     */
    static void clearRoomHistory(Context context, int roomId, boolean cancelNotification) {
        Log.d(TAG, "clearRoomHistory() roomId=" + roomId + " cancel=" + cancelNotification);
        roomMessages.remove(roomId);
        if (cancelNotification) {
            NotificationManager manager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
            if (manager != null) {
                manager.cancel(resolveNotificationId(roomId));
                postOrCancelGlobalSummary(context, manager);
            }
        }
    }

    /**
     * Public entry points to show a notification immediately.
     */
    static void showRoomNotification(Context context, String title, String body, int roomId, @Nullable String messageId, long timestamp) {
        showRoomNotification(context, title, body, roomId, 0, messageId, timestamp, false);
    }

    static void showRoomNotification(
        Context context,
        String title,
        String body,
        int roomId,
        int senderId,
        @Nullable String messageId,
        long timestamp,
        boolean isSync
    ) {
        if (addMessageToHistory(context, roomId, senderId, messageId, title, body, null, timestamp, isSync, null)) {
            triggerNotificationUpdate(context, roomId, title);
        }
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
        showRoomNotification(context, title, body, roomId, 0, roomName, messageId, timestamp, isSync);
    }

    static void showRoomNotification(
        Context context,
        String title,
        String body,
        int roomId,
        int senderId,
        @Nullable String roomName,
        @Nullable String messageId,
        long timestamp,
        boolean isSync
    ) {
        if (addMessageToHistory(context, roomId, senderId, messageId, title, body, roomName, timestamp, isSync, null)) {
            triggerNotificationUpdate(context, roomId, title);
        }
    }

    static void showRoomNotification(
        Context context,
        String title,
        String body,
        int roomId,
        int senderId,
        @Nullable String roomName,
        @Nullable String messageId,
        long timestamp,
        boolean isSync,
        @Nullable String avatarSvg
    ) {
        if (addMessageToHistory(context, roomId, senderId, messageId, title, body, roomName, timestamp, isSync, avatarSvg)) {
            triggerNotificationUpdate(context, roomId, title);
        }
    }

    /**
     * Adds a message to the history for a room. Returns true if it's a new/better message.
     */
    static boolean addMessageToHistory(
        Context context,
        int roomId,
        @Nullable String messageId,
        String title,
        String body,
        long timestamp,
        boolean isSync
    ) {
        return addMessageToHistory(context, roomId, 0, messageId, title, body, null, timestamp, isSync);
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
        return addMessageToHistory(context, roomId, senderId, messageId, title, body, roomName, timestamp, isSync, null);
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
        boolean isSync,
        @Nullable String avatarSvg
    ) {
        if (TextUtils.isEmpty(body)) return false;
        if (roomId <= 0) {
            Log.v(TAG, "Ignoring notification history for room 0");
            return false;
        }

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

        // Normalize sender name (for caching) and compute sender label (for notifications).
        String senderName = title;
        if (title != null && title.contains(" in ")) {
            senderName = title.split(" in ")[0];
        }

        // If the provided name is generic, try to recover from persisted caches
        if (isGenericTitle(senderName)) {
            // 1. Try by senderId if available
            if (senderId > 0) {
                String cachedUser = userNamesById.get(senderId);
                if (!isGenericTitle(cachedUser)) {
                    senderName = cachedUser;
                }
            }

            // 2. Try in-memory history for this session
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

            // 3. Fallback to room name if it's likely a 1-to-1 chat
            if (isGenericTitle(senderName) && roomId > 0) {
                String cachedRoomName = roomNamesById.get(roomId);
                if (!isGenericTitle(cachedRoomName)) {
                    senderName = cachedRoomName;
                }
            }
        }

        // If we have a valid name and senderId, persist it
        if (senderId > 0 && !isGenericTitle(senderName)) {
            setUserName(context, senderId, senderName);
        }

        if (senderName == null || isGenericTitle(senderName)) {
            senderName = getAppName(context);
        }

        // senderKey uses the senderId when available so two users with the same display
        // name are treated as distinct senders for deduplication purposes.
        String senderKey = senderId > 0 ? String.valueOf(senderId) : senderName;

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
                    Log.v(TAG, "Deduplicated by persistent ID: " + messageId);
                    return false;
                }
            }

            if (hasId) {
                loadDismissedIdsIfEmpty(context);
                if (dismissedMessageIds.contains(messageId)) {
                    Log.v(TAG, "Skipping dismissed message ID: " + messageId);
                    return false;
                }
            }

            if (roomId > 0 && hasServerTimestamp) {
                long dismissedUntil = getDismissedUntilForRoom(context, roomId);
                if (dismissedUntil > 0L && timestamp <= dismissedUntil) {
                    Log.v(
                        TAG,
                        "Skipping message at/before dismissed cutoff. roomId=" + roomId + " ts=" + timestamp + " cutoff=" + dismissedUntil
                    );
                    return false;
                }
            }

            MessageRecord newRec = new MessageRecord(messageId, senderName, senderKey, body, useTimestamp, hasServerTimestamp, avatarSvg);

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
                    senderKey.equals(rec.senderKey) &&
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

    /**
     * Renders and posts the notification based on current history.
     * Each room remains a child conversation notification under one app-level group.
     */
    static void triggerNotificationUpdate(Context context, int roomId, String title) {
        NotificationManager manager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
        if (manager == null) return;

        ensureChannel(manager);
        loadNamesIfEmpty(context);

        // Tap intent — opens the specific room
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

        // Dismiss intent
        Intent dismissIntent = new Intent(context, NotificationDismissReceiver.class);
        dismissIntent.putExtra(EXTRA_ROOM_ID, roomId);
        PendingIntent dismissPendingIntent = PendingIntent.getBroadcast(
            context,
            resolveRequestCode(roomId) + 1000000,
            dismissIntent,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );

        // Resolve conversation title (room name)
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

        // Create a shortcut for the room so Android 11+ shows the conversation avatar
        String shortcutId = "room_" + resolveNotificationId(roomId);
        Bitmap roomBitmap = buildInitialsBitmap(context, convTitle);
        IconCompat roomIconCompat = IconCompat.createWithBitmap(roomBitmap);

        ShortcutInfoCompat shortcutInfo = new ShortcutInfoCompat.Builder(context, shortcutId)
            .setShortLabel(convTitle)
            .setLongLabel(convTitle)
            .setIcon(roomIconCompat)
            .setIntent(intent != null ? intent : new Intent())
            .setLongLived(true)
            .setCategories(Collections.singleton("android.shortcut.conversation"))
            .build();
        ShortcutManagerCompat.pushDynamicShortcut(context, shortcutInfo);

        int notificationIconRes = getNotificationIconRes(context);
        // Build the child notification with MessagingStyle (all messages for this room)
        NotificationCompat.Builder builder = new NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(notificationIconRes)
            .setLargeIcon(roomBitmap)
            .setShortcutId(shortcutId)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setVibrate(new long[] { 0, 250, 250, 250 })
            .setAutoCancel(true)
            .setGroup(groupKeyAllRooms(context))
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
            .setOnlyAlertOnce(true)
            .setContentIntent(pendingIntent)
            .setDeleteIntent(dismissPendingIntent);

        List<MessageRecord> history = roomMessages.get(roomId);
        if (history != null && !history.isEmpty()) {
            Person user = new Person.Builder().setName("Me").build();

            NotificationCompat.MessagingStyle style = new NotificationCompat.MessagingStyle(user)
                .setConversationTitle(convTitle)
                .setGroupConversation(true);

            MessageRecord lastMsg = null;
            synchronized (history) {
                for (MessageRecord msg : history) {
                    // setKey() uses senderKey (senderId when known) so Android treats two
                    // users with the same display name as distinct people in MessagingStyle.
                    IconCompat senderIcon = buildSenderIcon(context, msg.avatarSvg, msg.sender);
                    Person sender = new Person.Builder()
                        .setName(nonEmptyOrDefault(msg.sender, "User"))
                        .setKey(msg.senderKey)
                        .setIcon(senderIcon)
                        .build();
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

        // Post the child notification FIRST so the system has the child before the summary is updated
        manager.notify(resolveNotificationId(roomId), builder.build());

        // Keep a single summary across all rooms (Signal-like bundle header)
        postOrCancelGlobalSummary(context, manager);
    }

    private static void postOrCancelGlobalSummary(Context context, NotificationManager manager) {
        int totalMessages = 0;
        int totalChats = 0;
        long latestTimestamp = 0;

        for (Map.Entry<Integer, List<MessageRecord>> entry : roomMessages.entrySet()) {
            Integer key = entry.getKey();
            if (key == null || key <= 0) {
                continue;
            }
            List<MessageRecord> history = entry.getValue();
            if (history == null) {
                continue;
            }
            int roomCount;
            synchronized (history) {
                roomCount = history.size();
                if (roomCount > 0) {
                    long roomLatest = history.get(roomCount - 1).timestamp;
                    if (roomLatest > latestTimestamp) {
                        latestTimestamp = roomLatest;
                    }
                }
            }
            if (roomCount <= 0) {
                continue;
            }
            totalChats++;
            totalMessages += roomCount;
        }

        if (totalMessages <= 0 || totalChats <= 0) {
            manager.cancel(GLOBAL_SUMMARY_NOTIFICATION_ID);
            return;
        }

        String appName = getAppName(context);
        String summaryTitle = appName + " \u2022 " + totalMessages + " messages";
        String summaryText = totalChats == 1 ? "1 chat" : totalChats + " chats";

        Intent summaryIntent = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
        if (summaryIntent != null) {
            summaryIntent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        }
        PendingIntent summaryPendingIntent = PendingIntent.getActivity(
            context,
            GLOBAL_SUMMARY_NOTIFICATION_ID,
            summaryIntent,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );

        int summaryIconRes = getNotificationIconRes(context);
        NotificationCompat.Builder summaryBuilder = new NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(summaryIconRes)
            .setContentTitle(summaryTitle)
            .setContentText(summaryText)
            .setNumber(totalMessages)
            .setGroup(groupKeyAllRooms(context))
            .setGroupSummary(true)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
            .setSilent(true)
            .setAutoCancel(true)
            .setContentIntent(summaryPendingIntent)
            .setStyle(new NotificationCompat.InboxStyle().setSummaryText(summaryText));

        if (latestTimestamp > 0) {
            summaryBuilder.setWhen(latestTimestamp);
        }

        manager.notify(GLOBAL_SUMMARY_NOTIFICATION_ID, summaryBuilder.build());
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
        // Clear this room's history and refresh the global summary.
        roomMessages.remove(roomId);
        NotificationManager manager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
        if (manager != null) {
            postOrCancelGlobalSummary(context, manager);
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
            } catch (JSONException e) {
                Log.w(TAG, "Failed to load recent IDs", e);
            }
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
            } catch (JSONException e) {
                Log.w(TAG, "Failed to load dismissed IDs", e);
            }
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
        } catch (JSONException e) {
            Log.w(TAG, "Failed to load dismissed cutoff by room", e);
        }
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
                    if (id > 0 && !TextUtils.isEmpty(name)) {
                        targetMap.put(id, name);
                    }
                } catch (NumberFormatException ignored) {}
            }
        } catch (JSONException e) {
            Log.w(TAG, "Failed to load map for " + key, e);
        }
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

    private static long getDismissedUntilForRoom(Context context, int roomId) {
        if (roomId <= 0) return 0L;
        loadDismissedCutoffByRoomIfEmpty(context);
        Long value = dismissedUntilByRoom.get(roomId);
        return value == null ? 0L : value;
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
            Integer roomId = entry.getKey();
            Long dismissedUntilTs = entry.getValue();
            if (roomId == null || dismissedUntilTs == null || roomId <= 0 || dismissedUntilTs <= 0L) continue;
            try {
                object.put(String.valueOf(roomId), dismissedUntilTs);
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

    private static IconCompat buildSenderIcon(Context context, @Nullable String avatarSvg, @Nullable String senderName) {
        Log.d(
            TAG,
            "buildSenderIcon: attempting to build icon for sender=" + senderName + ", avatarSvg present=" + !TextUtils.isEmpty(avatarSvg)
        );
        Bitmap avatarBitmap = renderAvatarSvg(avatarSvg);
        if (avatarBitmap != null) {
            Log.d(TAG, "buildSenderIcon: using rendered avatar bitmap");
            return IconCompat.createWithBitmap(avatarBitmap);
        }
        Log.d(TAG, "buildSenderIcon: avatar rendering failed or empty, using initials fallback for " + senderName);
        return IconCompat.createWithBitmap(buildInitialsBitmap(context, senderName));
    }

    @Nullable
    private static Bitmap renderAvatarSvg(@Nullable String avatarSvg) {
        if (TextUtils.isEmpty(avatarSvg)) {
            Log.d(TAG, "renderAvatarSvg: avatar_svg is empty");
            return null;
        }
        try {
            Log.d(TAG, "renderAvatarSvg: parsing SVG, length=" + avatarSvg.length());
            SVG svg = SVG.getFromString(avatarSvg);
            Log.d(TAG, "renderAvatarSvg: SVG parsed successfully, creating 128x128 bitmap");

            Bitmap bitmap = Bitmap.createBitmap(128, 128, Bitmap.Config.ARGB_8888);
            Canvas canvas = new Canvas(bitmap);

            // Set document size and render
            svg.setDocumentHeight(128f);
            svg.setDocumentWidth(128f);
            svg.setRenderDPI(96f);

            Log.d(TAG, "renderAvatarSvg: rendering SVG to canvas");
            svg.renderToCanvas(canvas);

            Log.d(TAG, "renderAvatarSvg: SVG rendered successfully");
            return bitmap;
        } catch (Exception e) {
            Log.e(TAG, "renderAvatarSvg: failed to render SVG", e);
            return null;
        }
    }

    private static Bitmap buildInitialsBitmap(Context context, @Nullable String senderName) {
        final int size = 128;
        String initials = resolveInitials(senderName);
        int baseColor = resolveColorFromText(senderName);

        Bitmap bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);

        Paint bgPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        bgPaint.setColor(baseColor);
        canvas.drawCircle(size / 2f, size / 2f, size / 2f, bgPaint);

        Paint textPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        textPaint.setColor(Color.WHITE);
        textPaint.setTextAlign(Paint.Align.CENTER);
        textPaint.setTextSize(size * 0.42f);
        textPaint.setFakeBoldText(true);

        Rect bounds = new Rect();
        textPaint.getTextBounds(initials, 0, initials.length(), bounds);
        float baseline = (size / 2f) - bounds.exactCenterY();
        canvas.drawText(initials, size / 2f, baseline, textPaint);

        return bitmap;
    }

    private static String resolveInitials(@Nullable String senderName) {
        if (TextUtils.isEmpty(senderName)) return "?";
        String trimmed = senderName.trim();
        if (trimmed.isEmpty()) return "?";
        String[] parts = trimmed.split("\\s+");
        if (parts.length >= 2) {
            String first = parts[0].substring(0, 1);
            String second = parts[1].substring(0, 1);
            return (first + second).toUpperCase();
        }
        return trimmed.substring(0, 1).toUpperCase();
    }

    private static int resolveColorFromText(@Nullable String text) {
        int hash = (text == null) ? 0 : text.hashCode();
        int r = 80 + Math.abs(hash % 120);
        int g = 80 + Math.abs((hash / 31) % 120);
        int b = 80 + Math.abs((hash / 131) % 120);
        return Color.rgb(r, g, b);
    }

    static boolean isNotificationActive(Context context, int roomId) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            NotificationManager manager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
            if (manager == null) return false;
            int targetId = resolveNotificationId(roomId);
            for (StatusBarNotification sbn : manager.getActiveNotifications()) {
                if (sbn != null && sbn.getId() == targetId) return true;
            }
            return false;
        }
        List<MessageRecord> history = roomMessages.get(roomId);
        return history != null && !history.isEmpty();
    }

    static void setRoomName(Context context, int roomId, @Nullable String roomName) {
        if (roomId <= 0 || TextUtils.isEmpty(roomName) || isGenericTitle(roomName)) return;
        roomNamesById.put(roomId, roomName);
        persistMapToPrefs(context, KEY_ROOM_NAMES, roomNamesById);
    }

    @Nullable
    static String getRoomName(int roomId) {
        if (roomId <= 0) return null;
        return roomNamesById.get(roomId);
    }

    static void setUserName(Context context, int userId, @Nullable String userName) {
        if (userId <= 0 || TextUtils.isEmpty(userName) || isGenericTitle(userName)) return;
        userNamesById.put(userId, userName);
        persistMapToPrefs(context, KEY_USER_NAMES, userNamesById);
    }

    @Nullable
    static String getUserName(int userId) {
        if (userId <= 0) return null;
        return userNamesById.get(userId);
    }

    private static int getNotificationIconRes(Context context) {
        int resId = context.getResources().getIdentifier("ic_notification", "drawable", context.getPackageName());
        return resId != 0 ? resId : android.R.drawable.ic_dialog_info;
    }

    private static String getAppName(Context context) {
        try {
            return context.getApplicationInfo().loadLabel(context.getPackageManager()).toString();
        } catch (Exception e) {
            return context.getPackageName();
        }
    }
}
