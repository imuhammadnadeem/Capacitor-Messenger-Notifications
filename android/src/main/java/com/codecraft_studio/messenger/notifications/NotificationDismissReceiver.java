package com.codecraft_studio.messenger.notifications;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

public class NotificationDismissReceiver extends BroadcastReceiver {

    private static final String TAG = "NotificationDismiss";

    @Override
    public void onReceive(Context context, Intent intent) {
        int roomId = intent.getIntExtra(NotificationHelper.EXTRA_ROOM_ID, 0);
        Log.d(TAG, "Notification dismissed for roomId: " + roomId);
        if (roomId > 0) {
            NotificationHelper.onNotificationDismissed(context, roomId);
        }
    }
}
