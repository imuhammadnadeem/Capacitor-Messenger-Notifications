package com.codecraft_studio.messenger.notifications;

import android.util.Log;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Tracks when a notification was last shown per room ID.
 * Used to avoid duplicate notifications.
 */
public final class FcmFetchManager {

    private static final String TAG = "FcmFetchManager";
    private static final Map<Integer, Long> lastRoomNotificationMs = new ConcurrentHashMap<>();
    private static final long NOTIFICATION_GRACE_MS = 10_000L;
    private static volatile long lastAnyNotificationMs = 0L;

    private FcmFetchManager() {}

    public static void markNotificationShown(int roomId) {
        long now = System.currentTimeMillis();
        lastRoomNotificationMs.put(roomId, now);
        lastAnyNotificationMs = now;
    }

    public static boolean wasNotificationShownRecently(int roomId) {
        Long last = lastRoomNotificationMs.get(roomId);
        if (last == null) return false;
        return (System.currentTimeMillis() - last) < NOTIFICATION_GRACE_MS;
    }

    public static boolean wasAnyNotificationShownRecently(long windowMs) {
        long last = lastAnyNotificationMs;
        if (last <= 0L) return false;
        return (System.currentTimeMillis() - last) < Math.max(0L, windowMs);
    }
}
