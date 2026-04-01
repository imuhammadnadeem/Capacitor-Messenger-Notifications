package com.codecraft_studio.messenger.notifications;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

public class NotificationDismissReceiver extends BroadcastReceiver {

    private static final String TAG = "NotificationDismissRcvr";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (context == null || intent == null) return;
        int roomId = intent.getIntExtra(NotificationHelper.EXTRA_ROOM_ID, 0);
        Log.d(TAG, "Notification dismissed from tray for roomId=" + roomId);
        NotificationHelper.onNotificationDismissed(context.getApplicationContext(), roomId);
    }
}
