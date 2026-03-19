package com.codecraft_studio.messenger.notifications;

import android.os.Bundle;
import android.util.Log;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

@CapacitorPlugin(name = "MessengerNotifications")
public class MessengerNotificationsPlugin extends Plugin {

    private static final String TAG = "MessengerNotifications";

    @Override
    public void load() {
        Log.i(TAG, "Plugin loaded");
    }

    @PluginMethod
    public void showNotification(PluginCall call) {
        String title = call.getString("title", "New Message");
        String body = call.getString("body", "You have a new message");
        int roomId = call.getInt("roomId", 0);
        String messageId = call.getString("messageId");
        long timestamp = call.getLong("timestamp", 0L);
        String roomName = call.getString("roomName");

        Log.i(TAG, "showNotification() title=" + title + " roomId=" + roomId + " messageId=" + messageId);

        NotificationHelper.showRoomNotification(getContext(), title, body, roomId, roomName, messageId, timestamp, false);
        call.resolve();
    }

    @PluginMethod
    public void clearRoomNotification(PluginCall call) {
        int roomId = call.getInt("roomId", 0);
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
        // Since we don't have MainActivity.pendingRoomId in a plugin,
        // we might want to store it in SharedPreferences or through a static field in the plugin.
        // For now, let's assume we store it in a static field here.
        Integer roomId = NotificationHelper.getPendingRoomId();
        if (roomId != null) {
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

        // Store these for the service to use (e.g. in SharedPreferences)
        getContext()
            .getSharedPreferences("messenger_plugin_prefs", android.content.Context.MODE_PRIVATE)
            .edit()
            .putString("socket_url", url)
            .putString("auth_token", token)
            .apply();

        PersistentSocketService.start(getContext());
        call.resolve();
    }

    @PluginMethod
    public void stopPersistentSocket(PluginCall call) {
        PersistentSocketService.stop(getContext());
        call.resolve();
    }
}
