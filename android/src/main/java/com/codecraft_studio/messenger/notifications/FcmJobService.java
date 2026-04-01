package com.codecraft_studio.messenger.notifications;

import android.app.job.JobInfo;
import android.app.job.JobParameters;
import android.app.job.JobScheduler;
import android.app.job.JobService;
import android.content.ComponentName;
import android.content.Context;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.RequiresApi;

import java.util.Collections;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Retry channel when direct FCM fetch path times out/fails.
 */
@RequiresApi(26)
public class FcmJobService extends JobService {

    private static final String TAG = "FcmJobService";
    private static final int JOB_ID = 1337;
    private static final long MIN_LATENCY_MS = 30_000L;
    private static final long OVERRIDE_DEADLINE_MS = 5 * 60_000L;
    private static final ExecutorService EXECUTOR = Executors.newSingleThreadExecutor();

    public static void schedule(@NonNull Context context) {
        JobInfo.Builder builder = new JobInfo.Builder(
                JOB_ID,
                new ComponentName(context, FcmJobService.class)
        )
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                .setBackoffCriteria(5_000L, JobInfo.BACKOFF_POLICY_LINEAR)
                .setMinimumLatency(MIN_LATENCY_MS)
                .setOverrideDeadline(OVERRIDE_DEADLINE_MS);

        JobScheduler scheduler = context.getSystemService(JobScheduler.class);
        if (scheduler != null) {
            scheduler.schedule(builder.build());
        }
    }

    @Override
    public boolean onStartJob(JobParameters params) {
        Log.d(TAG, "onStartJob()");
        EXECUTOR.execute(() -> {
            boolean success = FcmFetchManager.retrieveMessages(
                    getApplicationContext(),
                    Collections.emptyMap()
            );

            if (success) {
                FcmFetchManager.cancelMayHaveMessagesNotification(this);
                jobFinished(params, false);
            } else {
                jobFinished(params, true);
            }
        });
        return true;
    }

    @Override
    public boolean onStopJob(JobParameters params) {
        Log.d(TAG, "onStopJob()");
        return true;
    }
}
