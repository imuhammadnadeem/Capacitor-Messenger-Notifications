package com.codecraft_studio.messenger.notifications;

import android.app.Service;
import android.content.Intent;
import android.os.IBinder;
import android.util.Log;
import androidx.annotation.Nullable;

/**
 * Keeps the process alive in background while fetch tasks run.
 */
public class FcmFetchBackgroundService extends Service {

    private static final String TAG = "FcmFetchBackgroundSvc";

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        Log.i(TAG, "onDestroy()");
        super.onDestroy();
    }

    @Override
    public @Nullable IBinder onBind(Intent intent) {
        return null;
    }
}
