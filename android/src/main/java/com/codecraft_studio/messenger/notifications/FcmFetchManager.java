package com.codecraft_studio.messenger.notifications;

import android.Manifest;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;
import android.text.TextUtils;
import android.util.Log;

import androidx.core.app.NotificationCompat;
import androidx.core.app.NotificationManagerCompat;
import androidx.core.content.ContextCompat;

import android.os.PowerManager;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Signal-inspired fetch coordinator:
 * - keeps services alive while fetches run
 * - limits to ONE active fetch at a time to prevent socket "transport error" conflicts
 * - posts a fallback "may have messages" notification on repeated failures
 */
public final class FcmFetchManager {

    private static final String TAG = "FcmFetchManager";
    private static final ExecutorService EXECUTOR = Executors.newSingleThreadExecutor();

    public static final long WEBSOCKET_DRAIN_TIMEOUT_MS = 2 * 60 * 1000L;

    // Use 1 to prevent multiple parallel socket connections which cause "transport error"
    private static final int MAX_ACTIVE_FETCHES = 1; 
    private static final int MAY_HAVE_MESSAGES_NOTIFICATION_ID = 91002;
    private static final String MAY_HAVE_MESSAGES_CHANNEL_ID = "fcm_may_have_messages";

    private static int activeCount = 0;
    private static boolean highPriorityContext = false;
    private static Map<String, String> latestPayloadData = Collections.emptyMap();

    // Tracks when a notification was last shown per room ID.
    // Used to suppress the native fallback and avoid duplicate/overwriting notifications.
    private static final Map<Integer, Long> lastRoomNotificationMs = new ConcurrentHashMap<>();
    private static final long NOTIFICATION_GRACE_MS = 10_000L;
    private static volatile long lastAnyNotificationMs = 0L;

    private FcmFetchManager() {
    }

    public static synchronized boolean isFetchActive() {
        return activeCount > 0;
    }

    public static void startBackgroundService(Context context) {
        Log.i(TAG, "Starting background service");
        context.startService(new Intent(context, FcmFetchBackgroundService.class));
    }

    public static void startForegroundService(Context context) {
        Log.i(TAG, "Starting foreground service");
        FcmFetchForegroundService.startServiceIfNecessary(context);
    }

    public static void onForeground(Context context) {
        cancelMayHaveMessagesNotification(context);
    }

    /** Called when a notification is shown (either via WebView or Native socket). */
    public static void markNotificationShown(int roomId) {
        Log.d(TAG, "Marking notification shown for room: " + roomId);
        long now = System.currentTimeMillis();
        lastRoomNotificationMs.put(roomId, now);
        lastAnyNotificationMs = now;
    }

    /** Returns true if a notification was shown for this room within the grace window. */
    public static boolean wasNotificationShownRecently(int roomId) {
        Long last = lastRoomNotificationMs.get(roomId);
        if (last == null) return false;
        return (System.currentTimeMillis() - last) < NOTIFICATION_GRACE_MS;
    }

    /** Returns true if any notification was shown within the given window. */
    public static boolean wasAnyNotificationShownRecently(long windowMs) {
        long last = lastAnyNotificationMs;
        if (last <= 0L) {
            return false;
        }
        return (System.currentTimeMillis() - last) < Math.max(0L, windowMs);
    }

    public static void enqueueFetch(Context context, boolean highPriority, Map<String, String> payloadData) {
        Log.i(TAG, "[ENTRY][FCM_FETCH_MANAGER] enqueueFetch() highPriority=" + highPriority
                + " payloadKeys=" + (payloadData == null ? 0 : payloadData.size()));
        final Context appContext = context.getApplicationContext();
        synchronized (FcmFetchManager.class) {
            // if (shouldSkipRedundantFetch(payloadData)) {
            //     int roomId = parseInt(firstNonEmpty(
            //             payloadData != null ? payloadData.get("roomId") : null,
            //             payloadData != null ? payloadData.get("room_id") : null
            //     ), 0);
            //     Log.i(TAG, "Skipping native fetch: notification already shown recently for roomId=" + roomId);
            //     return;
            // }

            if (highPriority) {
                highPriorityContext = true;
            }

            if (payloadData != null && !payloadData.isEmpty()) {
                latestPayloadData = new HashMap<>(payloadData);
            }

            if (activeCount >= MAX_ACTIVE_FETCHES) {
                Log.i(TAG, "A fetch session is already active. Redundant trigger ignored.");
                return;
            }

            activeCount++;
            Log.i(TAG, "Starting fetch session (active count: " + activeCount + ")");
        }

        EXECUTOR.execute(() -> fetch(appContext));
    }

    private static boolean shouldSkipRedundantFetch(Map<String, String> payloadData) {
        if (payloadData == null || payloadData.isEmpty()) {
            return false;
        }
        int roomId = parseInt(firstNonEmpty(payloadData.get("roomId"), payloadData.get("room_id")), 0);
        if (roomId > 0 && wasNotificationShownRecently(roomId)) {
            return true;
        }
        // Conservative fallback for room-less pushes: only skip when any notification fired very recently.
        return roomId <= 0 && wasAnyNotificationShownRecently(3_000L);
    }

    public static boolean retrieveMessages(Context context, Map<String, String> payloadData) {
        Log.i(TAG, "[ENTRY][FCM_FETCH_MANAGER] retrieveMessages() -> socket first");
        boolean success = TemporarySocketSessionManager.runSession(context, payloadData);
        if (!success) {
            int roomId = 0;
            if (payloadData != null) {
                roomId = parseInt(firstNonEmpty(payloadData.get("roomId"), payloadData.get("room_id")), 0);
            }

            // If we recently showed a notification for this room (or generic),
            // skip the native fallback to prevent overwriting the decrypted one.
            if (wasNotificationShownRecently(roomId) || (roomId > 0 && wasNotificationShownRecently(0))) {
                Log.i(TAG, "Socket idle or failed but notification was shown recently - skipping fallback.");
                return true;
            }

            Log.w(TAG, "Socket session failed or produced no messages, trying Unread API fallback.");
            success = UnreadMessagesFetcher.fetchAndNotify(context, payloadData);
        }
        return success;
    }

    public static void cancelMayHaveMessagesNotification(Context context) {
        NotificationManagerCompat.from(context).cancel(MAY_HAVE_MESSAGES_NOTIFICATION_ID);
    }

    private static void fetch(Context context) {
        final boolean hasHighPriorityContext;
        final Map<String, String> payloadData;

        synchronized (FcmFetchManager.class) {
            hasHighPriorityContext = highPriorityContext;
            payloadData = new HashMap<>(latestPayloadData);
        }

        PowerManager pm = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
        PowerManager.WakeLock wakeLock = null;
        if (pm != null) {
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MessengerPlugin:FcmFetchWakeLock");
            wakeLock.acquire(WEBSOCKET_DRAIN_TIMEOUT_MS);
        }

        try {
            boolean success = retrieveMessages(context, payloadData);
            if (success) {
                cancelMayHaveMessagesNotification(context);
            } else if (hasHighPriorityContext) {
                postMayHaveMessagesNotification(context);
            }
        } finally {
            if (wakeLock != null && wakeLock.isHeld()) {
                wakeLock.release();
            }
        }

        synchronized (FcmFetchManager.class) {
            activeCount--;
            if (activeCount <= 0) {
                Log.i(TAG, "Fetch session complete. Stopping background services.");
                context.stopService(new Intent(context, FcmFetchBackgroundService.class));
                FcmFetchForegroundService.stopServiceIfNecessary(context);
                highPriorityContext = false;
                activeCount = 0;
            }
        }
    }

    private static void postMayHaveMessagesNotification(Context context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS)
                    != PackageManager.PERMISSION_GRANTED) {
                return;
            }
        }

        ensureMayHaveMessagesChannel(context);

        Intent launchIntent = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
        PendingIntent pendingIntent = null;
        if (launchIntent != null) {
            launchIntent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
            pendingIntent = PendingIntent.getActivity(
                    context,
                    0,
                    launchIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
            );
        }

        int notificationIconRes = context.getResources().getIdentifier("ic_notification", "drawable", context.getPackageName());
        if (notificationIconRes == 0) notificationIconRes = android.R.drawable.ic_dialog_info;

        NotificationCompat.Builder builder = new NotificationCompat.Builder(context, MAY_HAVE_MESSAGES_CHANNEL_ID)
                .setSmallIcon(notificationIconRes)
                .setContentTitle("New messages available")
                .setContentText("Tap to sync your encrypted chats")
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setOnlyAlertOnce(true)
                .setAutoCancel(true);

        if (pendingIntent != null) {
            builder.setContentIntent(pendingIntent);
        }

        NotificationManagerCompat.from(context).notify(MAY_HAVE_MESSAGES_NOTIFICATION_ID, builder.build());
    }

    private static void ensureMayHaveMessagesChannel(Context context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        if (manager == null) return;
        NotificationChannel channel = new NotificationChannel(
                MAY_HAVE_MESSAGES_CHANNEL_ID,
                "Message Alerts",
                NotificationManager.IMPORTANCE_DEFAULT
        );
        manager.createNotificationChannel(channel);
    }

    private static int parseInt(String value, int fallback) {
        if (TextUtils.isEmpty(value)) return fallback;
        try { return Integer.parseInt(value); } catch (Exception e) { return fallback; }
    }

    private static String firstNonEmpty(String... values) {
        if (values == null) return null;
        for (String v : values) if (!TextUtils.isEmpty(v)) return v;
        return null;
    }
}
