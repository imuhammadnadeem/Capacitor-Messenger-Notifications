package com.codecraft_studio.messenger.notifications;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Build;
import android.os.IBinder;
import android.text.TextUtils;
import android.util.Log;

import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;

import org.json.JSONObject;

import java.net.URISyntaxException;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

import io.socket.client.IO;
import io.socket.client.Socket;
import io.socket.engineio.client.transports.Polling;
import io.socket.engineio.client.transports.WebSocket;

/**
 * A persistent foreground service that maintains a WebSocket connection
 * for devices without GMS/FCM support.
 */
public class PersistentSocketService extends Service {

    private static final String TAG = "PersistentSocketSvc";
    private static final String CHANNEL_ID = "persistent_socket_channel_v5";
    private static final int NOTIFICATION_ID = 91005;

    private static final String DEFAULT_SOCKET_URL = "wss://4.rw";

    private static final Set<String> MESSAGE_EVENTS = new HashSet<>(Arrays.asList(
            "sync_messages_response",
            "sync:messages",
            "room:message_notification"
    ));

    private Socket mSocket;
    private SharedPreferences.OnSharedPreferenceChangeListener mPrefsListener;
    private String mCurrentToken;

    public static void start(Context context) {
        Intent intent = new Intent(context, PersistentSocketService.class);
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent);
            } else {
                context.startService(intent);
            }
        } catch (Exception e) {
            Log.e(TAG, "Failed to start PersistentSocketService", e);
        }
    }

    public static void stop(Context context) {
        context.stopService(new Intent(context, PersistentSocketService.class));
    }

    @Override
    public void onCreate() {
        super.onCreate();
        Log.i(TAG, "onCreate()");
        ensureChannel();
        startForeground(NOTIFICATION_ID, buildNotification("Initialising..."));
        setupPrefsListener();
        connectSocket();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        super.onDestroy();
        Log.i(TAG, "onDestroy()");
        if (mPrefsListener != null) {
            getSharedPreferences("safe_storage", MODE_PRIVATE).unregisterOnSharedPreferenceChangeListener(mPrefsListener);
        }
        disconnectSocket();
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private void setupPrefsListener() {
        mPrefsListener = (prefs, key) -> {
            if ("token".equals(key) || "authToken".equals(key)) {
                String newToken = firstNonEmpty(prefs.getString("token", null), prefs.getString("authToken", null));
                if (!TextUtils.equals(newToken, mCurrentToken)) {
                    Log.i(TAG, "Token changed, reconnecting socket...");
                    disconnectSocket();
                    connectSocket();
                }
            }
        };
        getSharedPreferences("safe_storage", MODE_PRIVATE).registerOnSharedPreferenceChangeListener(mPrefsListener);
    }

    private void connectSocket() {
        if (mSocket != null && mSocket.connected()) return;

        SharedPreferences prefs = getSharedPreferences("safe_storage", Context.MODE_PRIVATE);
        mCurrentToken = firstNonEmpty(prefs.getString("token", null), prefs.getString("authToken", null));
        String socketUrl = firstNonEmpty(prefs.getString("socketUrl", null), DEFAULT_SOCKET_URL);
        socketUrl = normalizeSocketBaseUrl(socketUrl);

        if (TextUtils.isEmpty(mCurrentToken) || TextUtils.isEmpty(socketUrl)) {
            Log.w(TAG, "Missing token or socket URL, waiting for login.");
            updateNotification("Waiting for login...");
            return;
        }

        try {
            IO.Options options = new IO.Options();
            options.forceNew = true;
            options.reconnection = true;
            options.reconnectionDelay = 5000;
            options.reconnectionDelayMax = 30000;
            options.timeout = 20000;
            options.transports = new String[]{WebSocket.NAME, Polling.NAME};

            if (!setAuthIfSupported(options, mCurrentToken)) {
                options.query = "token=" + mCurrentToken;
            }

            Log.i(TAG, "Connecting to " + socketUrl);
            mSocket = IO.socket(socketUrl, options);

            mSocket.on(Socket.EVENT_CONNECT, args -> {
                Log.i(TAG, "Socket connected");
                updateNotification("Connected");
                mSocket.emit("sync_messages");
            });

            mSocket.on(Socket.EVENT_DISCONNECT, args -> {
                Log.i(TAG, "Socket disconnected: " + (args.length > 0 ? args[0] : "unknown"));
                updateNotification("Reconnecting...");
            });

            mSocket.on(Socket.EVENT_CONNECT_ERROR, args -> {
                Log.w(TAG, "Socket connection error: " + (args.length > 0 ? args[0] : "unknown"));
                updateNotification("Connection error, retrying...");
            });

            mSocket.onAnyIncoming(args -> {
                if (args != null && args.length > 0) {
                    String event = String.valueOf(args[0]);
                    if (MESSAGE_EVENTS.contains(event)) {
                        Object[] payloadArgs = args.length > 1 ? Arrays.copyOfRange(args, 1, args.length) : new Object[0];
                        handleSocketMessage(event, payloadArgs);
                    }
                }
            });

            mSocket.connect();
        } catch (URISyntaxException e) {
            Log.e(TAG, "Invalid socket URL", e);
            updateNotification("Configuration error");
        }
    }

    private void handleSocketMessage(String event, Object[] args) {
        if (args == null || args.length == 0) return;
        boolean syncReceived = "sync_messages_response".equals(event);
        for (Object arg : args) {
            boolean notified = syncReceived
                    ? EncryptedMessageNotifier.notifyFromSyncMessagesResponse(this, arg)
                    : EncryptedMessageNotifier.notifyFromSocketPayload(this, arg);

            if (!notified && syncReceived && arg instanceof JSONObject) {
                EncryptedMessageNotifier.notifyFromUnreadApiRecord(this, (JSONObject) arg);
            }
        }
    }

    private void disconnectSocket() {
        if (mSocket != null) {
            mSocket.off();
            mSocket.disconnect();
            mSocket.close();
            mSocket = null;
        }
    }

    private void ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID,
                    "Persistent Connection",
                    NotificationManager.IMPORTANCE_MIN
            );
            channel.setDescription("Maintains connection to receive messages when FCM is unavailable");
            channel.setShowBadge(false);
            channel.enableVibration(false);
            channel.setSound(null, null);
            channel.setLockscreenVisibility(Notification.VISIBILITY_SECRET);
            NotificationManager manager = getSystemService(NotificationManager.class);
            if (manager != null) {
                manager.createNotificationChannel(channel);
            }
        }
    }

    private Notification buildNotification(String contentText) {
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

        int transparentIconRes = getResources().getIdentifier("ic_transparent", "drawable", getPackageName());
        if (transparentIconRes == 0) transparentIconRes = android.R.drawable.ic_delete;

        return new NotificationCompat.Builder(this, CHANNEL_ID)
                .setSmallIcon(transparentIconRes)
                .setContentTitle(getAppName())
                .setContentText(contentText)
                .setOngoing(true)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .setPriority(NotificationCompat.PRIORITY_MIN)
                .setBadgeIconType(NotificationCompat.BADGE_ICON_NONE)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .setContentIntent(pendingIntent)
                .build();
    }

    private void updateNotification(String contentText) {
        NotificationManager manager = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (manager != null) {
            manager.notify(NOTIFICATION_ID, buildNotification(contentText));
        }
    }

    private String getAppName() {
        try {
            return getApplicationInfo().loadLabel(getPackageManager()).toString();
        } catch (Exception e) {
            return getPackageName();
        }
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

    private static String normalizeSocketBaseUrl(String baseUrl) {
        if (TextUtils.isEmpty(baseUrl)) return null;
        String normalized = baseUrl.trim();
        if (normalized.endsWith("/")) normalized = normalized.substring(0, normalized.length() - 1);
        if (normalized.endsWith("/api")) normalized = normalized.substring(0, normalized.length() - 4);
        if (!normalized.contains("://")) normalized = "https://" + normalized;
        return normalized;
    }

    private static String firstNonEmpty(String... values) {
        for (String v : values) if (!TextUtils.isEmpty(v) && !"null".equalsIgnoreCase(v)) return v;
        return null;
    }
}
