package com.codecraft_studio.messenger.notifications;

import android.text.TextUtils;
import android.util.Log;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

@CapacitorPlugin(name = "MessengerNotifications")
public class MessengerNotificationsPlugin extends Plugin {

    private static final String TAG = "MessengerNotifications";
    private static final long BRIDGE_DUPLICATE_WINDOW_MS = 4_000L;
    private static volatile String lastBridgeMessageId;
    private static volatile long lastBridgeShownAtMs;

    @Override
    public void load() {
        Log.i(TAG, "Plugin loaded – injecting Notification polyfill");
        injectNotificationPolyfill();
    }

    @PluginMethod
    public void showNotification(PluginCall call) {
        String title = call.getString("title", "New Message");
        String body = call.getString("body", "You have a new message");
        int roomId = resolveRoomId(call);
        String roomName = call.getString("roomName");
        String avatarSvg = call.getString("avatarSvg");

        String messageId = call.getString("messageId");
        if (messageId == null) {
            Object mid = call.getData().opt("messageId");
            if (mid != null) messageId = String.valueOf(mid);
        }

        long timestamp = call.getLong("timestamp", 0L);
        int senderId = call.getInt("senderId", 0);

        Log.i(TAG, "showNotification() title=" + title + " roomId=" + roomId + " senderId=" + senderId + " messageId=" + messageId);

        if (shouldSuppressDuplicateBridgeNotification(title, body, roomId, messageId)) {
            Log.i(TAG, "Suppressing bridge duplicate notification");
            call.resolve();
            return;
        }

        NotificationHelper.showRoomNotification(getContext(), title, body, roomId, senderId, roomName, messageId, timestamp, false, avatarSvg);
        call.resolve();
    }

    @PluginMethod
    public void clearRoomNotification(PluginCall call) {
        int roomId = resolveRoomId(call);
        if (roomId <= 0) {
            call.resolve();
            return;
        }

        Log.i(TAG, "clearRoomNotification() roomId=" + roomId);
        NotificationHelper.clearRoomHistory(getContext(), roomId, true);
        call.resolve();
    }

    @PluginMethod
    public void getPendingRoomId(PluginCall call) {
        JSObject result = new JSObject();
        Integer roomId = NotificationHelper.getPendingRoomId();
        if (roomId != null) {
            Log.i(TAG, "getPendingRoomId() returning roomId=" + roomId);
            result.put("roomId", roomId);
            NotificationHelper.consumePendingRoomId();
        } else {
            result.put("roomId", JSObject.NULL);
        }
        call.resolve(result);
    }

    @PluginMethod
    public void startPersistentSocket(PluginCall call) {
        String url = call.getString("url");
        String token = call.getString("token");

        if (url == null || token == null) {
            call.reject("Missing url or token");
            return;
        }

        getContext()
            .getSharedPreferences("safe_storage", android.content.Context.MODE_PRIVATE)
            .edit()
            .putString("socketUrl", url)
            .putString("token", token)
            .apply();

        if (!GmsHelper.isGmsAvailable(getContext())) {
            PersistentSocketService.start(getContext());
        }

        call.resolve();
    }

    @PluginMethod
    public void stopPersistentSocket(PluginCall call) {
        PersistentSocketService.stop(getContext());
        call.resolve();
    }

    @PluginMethod
    public void checkPermissions(PluginCall call) {
        JSObject result = new JSObject();
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            boolean granted = androidx.core.content.ContextCompat.checkSelfPermission(
                    getContext(), android.Manifest.permission.POST_NOTIFICATIONS)
                    == android.content.pm.PackageManager.PERMISSION_GRANTED;
            result.put("notifications", granted ? "granted" : "denied");
        } else {
            result.put("notifications", "granted");
        }
        call.resolve(result);
    }

    @PluginMethod
    public void requestPermissions(PluginCall call) {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            requestPermissionForAlias("notifications", call, "checkPermissionsCallback");
        } else {
            JSObject result = new JSObject();
            result.put("notifications", "granted");
            call.resolve(result);
        }
    }

    @PluginMethod
    public void registerFcmToken(PluginCall call) {
        FcmTokenRegistrar.registerIfPossible(getContext());
        call.resolve();
    }

    // -------------------------------------------------------------------------
    // Polyfill injection
    // -------------------------------------------------------------------------

    private void injectNotificationPolyfill() {
        String polyfill =
            "(function() {" +
            "  if ('Notification' in window) {" +
            "    console.log('[MessengerNotifications] Notification already present, polyfill skipped.');" +
            "    return;" +
            "  }" +
            "  try {" +
            "    var swDesc = Object.getOwnPropertyDescriptor(navigator, 'serviceWorker')" +
            "                 || Object.getOwnPropertyDescriptor(Navigator.prototype, 'serviceWorker');" +
            "    if (swDesc && swDesc.configurable !== false) {" +
            "      Object.defineProperty(navigator, 'serviceWorker', {" +
            "        configurable: true," +
            "        enumerable: true," +
            "        get: function() { return undefined; }" +
            "      });" +
            "    }" +
            "  } catch(e) {" +
            "    console.warn('[MessengerNotifications] Could not override navigator.serviceWorker:', e);" +
            "  }" +
            "  function AndroidNotification(title, opts) {" +
            "    this.title = title || '';" +
            "    this.body = (opts && opts.body) ? opts.body : '';" +
            "    var roomId = 0;" +
            "    var messageId = (opts && opts.messageId) ? opts.messageId : null;" +
            "    var timestamp = (opts && opts.timestamp) ? opts.timestamp : 0;" +
            "    var roomName = null;" +
            "    var senderId = 0;" +
            "    var avatarSvg = null;" +
            "    if (opts) {" +
            "      if (typeof opts.roomId === 'number') {" +
            "        roomId = opts.roomId;" +
            "      } else if (typeof opts.roomId === 'string') {" +
            "        var rid = parseInt(opts.roomId, 10);" +
            "        roomId = isNaN(rid) ? 0 : rid;" +
            "      } else if (opts.data && typeof opts.data.roomId === 'number') {" +
            "        roomId = opts.data.roomId;" +
            "      } else if (opts.data && typeof opts.data.roomId === 'string') {" +
            "        var drid = parseInt(opts.data.roomId, 10);" +
            "        roomId = isNaN(drid) ? 0 : drid;" +
            "      }" +
            "      if (opts.data) {" +
            "        if (opts.data.messageId) messageId = opts.data.messageId;" +
            "        if (opts.data.timestamp) timestamp = opts.data.timestamp;" +
            "        if (opts.data.roomName) roomName = opts.data.roomName;" +
            "        if (opts.data.avatarSvg) avatarSvg = opts.data.avatarSvg;" +
            "        if (opts.data.senderId) {" +
            "          var sid = typeof opts.data.senderId === 'number' ? opts.data.senderId : parseInt(opts.data.senderId, 10);" +
            "          senderId = isNaN(sid) ? 0 : sid;" +
            "        }" +
            "      }" +
            "    }" +
            "    var cap = window.Capacitor;" +
            "    if (cap && cap.Plugins && cap.Plugins.MessengerNotifications) {" +
            "      cap.Plugins.MessengerNotifications.showNotification({" +
            "        title: this.title," +
            "        body: this.body," +
            "        roomId: roomId," +
            "        messageId: messageId," +
            "        timestamp: timestamp," +
            "        roomName: roomName," +
            "        senderId: senderId," +
            "        avatarSvg: avatarSvg" +
            "      }).catch(function(err) {" +
            "        console.warn('[MessengerNotifications] showNotification error:', err);" +
            "      });" +
            "    } else {" +
            "      console.warn('[MessengerNotifications] Capacitor plugin not ready yet.');" +
            "    }" +
            "  }" +
            "  AndroidNotification.prototype.close = function() {};" +
            "  Object.defineProperty(AndroidNotification.prototype, 'onclick', {" +
            "    set: function(fn) { this._onclick = fn; }," +
            "    get: function() { return this._onclick || null; }" +
            "  });" +
            "  AndroidNotification.permission = 'granted';" +
            "  AndroidNotification.requestPermission = function() { return Promise.resolve('granted'); };" +
            "  window.Notification = AndroidNotification;" +
            "  console.log('[MessengerNotifications] window.Notification polyfill installed.');" +
            "})();";

        getBridge().getWebView().post(() ->
            getBridge().getWebView().evaluateJavascript(polyfill, null)
        );
    }

    private static int resolveRoomId(PluginCall call) {
        Integer maybeInt = call.getInt("roomId");
        if (maybeInt != null) return maybeInt;

        String maybeString = call.getString("roomId");
        if (!TextUtils.isEmpty(maybeString)) {
            try {
                return Integer.parseInt(maybeString);
            } catch (NumberFormatException ignored) {
                return 0;
            }
        }
        return 0;
    }

    private static boolean shouldSuppressDuplicateBridgeNotification(String title, String body, int roomId, String messageId) {
        String safeMessageId = TextUtils.isEmpty(messageId) ? null : messageId.trim();
        long now = System.currentTimeMillis();

        if (TextUtils.isEmpty(safeMessageId)) {
            Log.i(TAG, "Suppressing bridge notification without messageId");
            return true;
        }

        if (!TextUtils.isEmpty(safeMessageId)) {
            String lastId = lastBridgeMessageId;
            long lastAt = lastBridgeShownAtMs;
            if (safeMessageId.equals(lastId) && (now - lastAt) < BRIDGE_DUPLICATE_WINDOW_MS) {
                return true;
            }
            lastBridgeMessageId = safeMessageId;
            lastBridgeShownAtMs = now;
            return false;
        }

        if (roomId > 0 && FcmFetchManager.wasNotificationShownRecently(roomId)) return true;
        if (roomId <= 0 && FcmFetchManager.wasAnyNotificationShownRecently(BRIDGE_DUPLICATE_WINDOW_MS)) return true;

        return false;
    }
}
