package com.codecraft_studio.messenger.notifications;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;
import android.util.Log;

import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;
import androidx.core.content.ContextCompat;

/**
 * Foreground keep-alive service for high-priority FCM fetch flow.
 */
public class FcmFetchForegroundService extends Service {

    private static final String TAG = "FcmFetchForegroundSvc";
    private static final String CHANNEL_ID = "fcm_fetch_service";
    private static final int FOREGROUND_NOTIFICATION_ID = 91001;
    private static final String KEY_STOP_SELF = "stop_self";
    private static final String WAKELOCK_TAG = "MessengerPlugin:FcmFetch";

    private static final Object LOCK = new Object();
    private static boolean running = false;

    private PowerManager.WakeLock wakeLock;

    public static boolean startServiceIfNecessary(Context context) {
        synchronized (LOCK) {
            if (running) {
                return true;
            }

            Intent intent = new Intent(context, FcmFetchForegroundService.class);
            try {
                ContextCompat.startForegroundService(context, intent);
                running = true;
                return true;
            } catch (RuntimeException e) {
                Log.w(TAG, "Failed to start foreground service", e);
                running = false;
                return false;
            }
        }
    }

    public static void stopServiceIfNecessary(Context context) {
        synchronized (LOCK) {
            if (!running) {
                return;
            }

            Intent intent = new Intent(context, FcmFetchForegroundService.class);
            intent.putExtra(KEY_STOP_SELF, true);
            try {
                context.startService(intent);
            } catch (RuntimeException e) {
                Log.w(TAG, "Failed to stop foreground service", e);
                running = false;
            }
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        ensureChannel();
        startForeground(FOREGROUND_NOTIFICATION_ID, buildNotification());

        boolean stopSelf = intent != null && intent.getBooleanExtra(KEY_STOP_SELF, false);
        if (stopSelf) {
            releaseWakeLock();
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE);
            } else {
                stopForeground(true);
            }
            stopSelf();
            return START_NOT_STICKY;
        }

        acquireWakeLockIfNeeded();
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        super.onDestroy();
        releaseWakeLock();
        synchronized (LOCK) {
            running = false;
        }
    }

    @Override
    public @Nullable IBinder onBind(Intent intent) {
        return null;
    }

    private void acquireWakeLockIfNeeded() {
        if (wakeLock != null && wakeLock.isHeld()) {
            return;
        }

        PowerManager powerManager = (PowerManager) getSystemService(POWER_SERVICE);
        if (powerManager == null) {
            return;
        }

        wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKELOCK_TAG);
        wakeLock.setReferenceCounted(false);
        wakeLock.acquire(FcmFetchManager.WEBSOCKET_DRAIN_TIMEOUT_MS);
    }

    private void releaseWakeLock() {
        try {
            if (wakeLock != null && wakeLock.isHeld()) {
                wakeLock.release();
            }
        } catch (RuntimeException e) {
            Log.w(TAG, "Failed to release wakelock", e);
        } finally {
            wakeLock = null;
        }
    }

    private void ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return;
        }

        NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID,
                "Message Sync",
                NotificationManager.IMPORTANCE_LOW
        );
        channel.setDescription("Keeps message sync alive for incoming push notifications");

        NotificationManager manager = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (manager != null) {
            manager.createNotificationChannel(channel);
        }
    }

    private Notification buildNotification() {
        Intent launchIntent = getPackageManager().getLaunchIntentForPackage(getPackageName());
        PendingIntent pendingIntent = null;
        if (launchIntent != null) {
            launchIntent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
            pendingIntent = PendingIntent.getActivity(
                    this,
                    0,
                    launchIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
            );
        }

        int iconRes = getResources().getIdentifier("ic_notification", "drawable", getPackageName());
        if (iconRes == 0) iconRes = android.R.drawable.ic_dialog_info;

        NotificationCompat.Builder builder = new NotificationCompat.Builder(this, CHANNEL_ID)
                .setSmallIcon(iconRes)
                .setContentTitle("Syncing messages")
                .setContentText("Checking for new encrypted messages")
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setVibrate(new long[]{0});

        if (pendingIntent != null) {
            builder.setContentIntent(pendingIntent);
        }

        return builder.build();
    }
}
