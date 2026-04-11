package com.codecraft_studio.messenger.notifications;

import android.content.Context;
import android.content.SharedPreferences;
import android.text.TextUtils;
import android.util.Log;
import androidx.annotation.Nullable;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.json.JSONObject;

final class MessageFlowLogger {

    private static final String TAG = "MessageFlowLogger";
    private static final ExecutorService EXECUTOR = Executors.newSingleThreadExecutor();
    private static final String DEFAULT_BASE_URL = "https://4.rw";
    private static final List<String> BASE_URL_PREF_KEYS = Arrays.asList(
        "backendBaseUrl",
        "backend_url",
        "apiBaseUrl",
        "api_base_url",
        "serverUrl",
        "server_url"
    );

    private MessageFlowLogger() {}

    static void log(
        Context context,
        String traceId,
        @Nullable String messageId,
        @Nullable Integer roomId,
        @Nullable Integer userId,
        String stepKey,
        String stepMessage,
        String channel,
        String status,
        @Nullable JSONObject payload,
        @Nullable String error
    ) {
        Context app = context.getApplicationContext();
        EXECUTOR.execute(() -> postLog(app, traceId, messageId, roomId, userId, stepKey, stepMessage, channel, status, payload, error));
    }

    private static void postLog(
        Context context,
        String traceId,
        @Nullable String messageId,
        @Nullable Integer roomId,
        @Nullable Integer userId,
        String stepKey,
        String stepMessage,
        String channel,
        String status,
        @Nullable JSONObject payload,
        @Nullable String error
    ) {
        HttpURLConnection conn = null;
        try {
            String endpoint = normalizeBaseUrl(resolveBaseUrl(context)) + "/api/message-flow-logs/ingest";
            URL url = new URL(endpoint);

            JSONObject body = new JSONObject();
            body.put("trace_id", traceId);
            body.put("step_key", stepKey);
            body.put("step_message", stepMessage);
            body.put("platform", "android");
            body.put("source", "mobile-native");
            body.put("channel", channel);
            body.put("status", status);
            body.put(
                "created_at",
                new java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", java.util.Locale.US).format(new java.util.Date())
            );

            if (!TextUtils.isEmpty(messageId)) {
                try {
                    body.put("message_id", Integer.parseInt(messageId));
                } catch (Exception e) {
                    body.put("message_id", messageId);
                }
            }
            if (roomId != null && roomId > 0) {
                body.put("room_id", roomId);
            }
            Integer resolvedUserId = userId != null ? userId : resolveUserId(context);
            if (resolvedUserId != null && resolvedUserId > 0) {
                body.put("user_id", resolvedUserId);
            }
            if (payload != null) {
                body.put("payload", payload);
            }
            if (!TextUtils.isEmpty(error)) {
                body.put("error", error);
            }

            conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("POST");
            conn.setConnectTimeout(5000);
            conn.setReadTimeout(7000);
            conn.setDoOutput(true);
            conn.setRequestProperty("Content-Type", "application/json");

            byte[] bytes = body.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8);
            try (OutputStream os = conn.getOutputStream()) {
                os.write(bytes);
            }

            int code = conn.getResponseCode();
            if (code < 200 || code >= 300) {
                Log.d(TAG, "log post non-2xx code=" + code + " step=" + stepKey);
            }
        } catch (Exception e) {
            Log.d(TAG, "log post failed step=" + stepKey + " err=" + e.getMessage());
        } finally {
            if (conn != null) conn.disconnect();
        }
    }

    private static String resolveBaseUrl(Context context) {
        SharedPreferences prefs = context.getSharedPreferences("safe_storage", Context.MODE_PRIVATE);
        for (String key : BASE_URL_PREF_KEYS) {
            String value = prefs.getString(key, null);
            if (!TextUtils.isEmpty(value)) return value;
        }
        return DEFAULT_BASE_URL;
    }

    private static String normalizeBaseUrl(String base) {
        String v = base == null ? DEFAULT_BASE_URL : base.trim();
        if (v.endsWith("/")) v = v.substring(0, v.length() - 1);
        return v;
    }

    @Nullable
    private static Integer resolveUserId(Context context) {
        SharedPreferences prefs = context.getSharedPreferences("safe_storage", Context.MODE_PRIVATE);
        String raw = prefs.getString("userId", null);
        if (TextUtils.isEmpty(raw)) return null;
        try {
            return Integer.parseInt(raw);
        } catch (Exception e) {
            return null;
        }
    }
}
