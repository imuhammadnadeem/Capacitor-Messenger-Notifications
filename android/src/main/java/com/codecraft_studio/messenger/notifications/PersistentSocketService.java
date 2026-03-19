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
import io.socket.client.IO;
import io.socket.client.Socket;
import io.socket.engineio.client.transports.Polling;
import io.socket.engineio.client.transports.WebSocket;
import java.net.URISyntaxException;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import org.json.JSONObject;

public class PersistentSocketService extends Service {

    private static final String TAG = "PersistentSocketSvc";
    private static final String CHANNEL_ID = "persistent_socket_channel";
    private static final int NOTIFICATION_ID = 91005;

    private static final Set<String> MESSAGE_EVENTS = new HashSet<>(
        Arrays.asList("sync_messages_response", "sync:messages", "room:message_notification")
    );

    private Socket mSocket;
    private SharedPreferences.OnSharedPreferenceChangeListener mPrefsListener;
    private String mCurrentToken;

    public static void start(Context context) {
        Intent intent = new Intent(context, PersistentSocketService.class);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent);
        } else {
            context.startService(intent);
        }
    }

    public static void stop(Context context) {
        context.stopService(new Intent(context, PersistentSocketService.class));
    }

    @Override
    public void onCreate() {
        super.onCreate();
        ensureChannel();
        startForeground(NOTIFICATION_ID, buildNotification("Messaging Active"));
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
        if (mPrefsListener != null) {
            getSharedPreferences("messenger_plugin_prefs", MODE_PRIVATE).unregisterOnSharedPreferenceChangeListener(mPrefsListener);
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
            if ("auth_token".equals(key)) {
                String newToken = prefs.getString("auth_token", null);
                if (!TextUtils.equals(newToken, mCurrentToken)) {
                    disconnectSocket();
                    connectSocket();
                }
            }
        };
        getSharedPreferences("messenger_plugin_prefs", MODE_PRIVATE).registerOnSharedPreferenceChangeListener(mPrefsListener);
    }

    private synchronized void connectSocket() {
        if (mSocket != null && mSocket.connected()) return;

        SharedPreferences prefs = getSharedPreferences("messenger_plugin_prefs", Context.MODE_PRIVATE);
        mCurrentToken = prefs.getString("auth_token", null);
        String socketUrl = prefs.getString("socket_url", null);

        if (TextUtils.isEmpty(mCurrentToken) || TextUtils.isEmpty(socketUrl)) {
            updateNotification("Waiting for credentials...");
            return;
        }

        try {
            IO.Options options = new IO.Options();
            options.forceNew = true;
            options.reconnection = true;
            options.reconnectionDelay = 5000;
            options.reconnectionDelayMax = 30000;
            options.timeout = 20000;
            options.transports = new String[] { WebSocket.NAME, Polling.NAME };

            // Socket.IO v4.x auth mechanism
            Map<String, String> auth = new HashMap<>();
            auth.put("token", mCurrentToken);
            options.auth = auth;

            mSocket = IO.socket(socketUrl, options);

            mSocket.on(Socket.EVENT_CONNECT, (args) -> {
                updateNotification("Connected");
                mSocket.emit("sync_messages");
            });

            mSocket.on(Socket.EVENT_DISCONNECT, (args) -> {
                updateNotification("Reconnecting...");
            });

            mSocket.on(Socket.EVENT_CONNECT_ERROR, (args) -> {
                updateNotification("Connection error, retrying...");
            });

            mSocket.onAnyIncoming((args) -> {
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
        }
    }

    private void handleSocketMessage(String event, Object[] args) {
        if (args == null || args.length == 0) return;
        boolean syncReceived = "sync_messages_response".equals(event);
        for (Object arg : args) {
            if (syncReceived) {
                EncryptedMessageNotifier.notifyFromSyncMessagesResponse(this, arg);
            } else {
                EncryptedMessageNotifier.notifyFromSocketPayload(this, arg);
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
            NotificationChannel channel = new NotificationChannel(CHANNEL_ID, "Messaging Connection", NotificationManager.IMPORTANCE_LOW);
            channel.setDescription("Maintains messaging connection background");
            NotificationManager manager = getSystemService(NotificationManager.class);
            if (manager != null) manager.createNotificationChannel(channel);
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

        return new NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(getApplicationInfo().icon)
            .setContentTitle("Chat Messenger")
            .setContentText(contentText)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setOnlyAlertOnce(true)
            .setContentIntent(pendingIntent)
            .build();
    }

    private void updateNotification(String contentText) {
        NotificationManager manager = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (manager != null) manager.notify(NOTIFICATION_ID, buildNotification(contentText));
    }
}
