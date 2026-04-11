package com.codecraft_studio.messenger.notifications;

import android.content.Context;
import android.content.SharedPreferences;
import android.text.TextUtils;
import android.util.Log;

import androidx.annotation.Nullable;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.List;
import java.util.Map;

final class UnreadMessagesFetcher {

    private static final String TAG = "UnreadMessagesFetcher";
    private static final int CONNECT_TIMEOUT_MS = 8000;
    private static final int READ_TIMEOUT_MS = 12000;
    private static final String DEFAULT_BASE_URL = "https://4.rw";
    private static final List<String> BASE_URL_PREF_KEYS = Arrays.asList(
            "backendBaseUrl",
            "backend_url",
            "apiBaseUrl",
            "api_base_url",
            "serverUrl",
            "server_url"
    );

    private UnreadMessagesFetcher() {
    }

    static boolean fetchAndNotify(Context context, @Nullable Map<String, String> payloadData) {
        try {
            boolean fetched = fetchUnreadFromApi(context, payloadData);
            if (fetched) {
                return true;
            }
        } catch (Exception e) {
            Log.w(TAG, "Unread fetch failed: " + e.getMessage(), e);
        }

        return showFallbackNotification(context, payloadData);
    }

    private static boolean fetchUnreadFromApi(Context context, @Nullable Map<String, String> payloadData) throws Exception {
        SharedPreferences prefs = context.getSharedPreferences("safe_storage", Context.MODE_PRIVATE);
        String token = firstNonEmpty(prefs.getString("token", null), prefs.getString("authToken", null));
        if (TextUtils.isEmpty(token)) {
            Log.i(TAG, "No auth token in safe storage.");
            return false;
        }

        String unreadUrl = resolveUnreadUrl(prefs, payloadData);
        if (TextUtils.isEmpty(unreadUrl)) {
            Log.i(TAG, "No unread endpoint configured.");
            return false;
        }

        MessageFlowLogger.log(
            context,
            "android-unread-" + System.currentTimeMillis(),
            null,
            null,
            null,
            "android_unread_fetch_started",
            "Android started unread API fetch",
            "api",
            "start",
            null,
            null
        );

        HttpURLConnection connection = null;
        try {
            connection = (HttpURLConnection) new URL(unreadUrl).openConnection();
            connection.setRequestMethod("GET");
            connection.setConnectTimeout(CONNECT_TIMEOUT_MS);
            connection.setReadTimeout(READ_TIMEOUT_MS);
            connection.setRequestProperty("Authorization", "Bearer " + token);
            connection.setRequestProperty("Accept", "application/json");

            int responseCode = connection.getResponseCode();
            if (responseCode != HttpURLConnection.HTTP_OK) {
                String errorBody = readStream(connection.getErrorStream());
                Log.w(TAG, "Unread API failed: " + responseCode + " body=" + errorBody);
                return false;
            }

            String response = readStream(connection.getInputStream());
            if (TextUtils.isEmpty(response)) {
                return true;
            }

            JSONObject jsonResponse = new JSONObject(response);
            JSONArray messages = jsonResponse.optJSONArray("messages");
            if (messages == null) {
                MessageFlowLogger.log(
                    context,
                    "android-unread-" + System.currentTimeMillis(),
                    null,
                    null,
                    null,
                    "android_unread_fetch_completed",
                    "Android unread API completed with 0 messages",
                    "api",
                    "success",
                    null,
                    null
                );
                return true;
            }

                JSONObject p = new JSONObject();
                p.put("message_count", messages.length());
                MessageFlowLogger.log(
                    context,
                    "android-unread-" + System.currentTimeMillis(),
                    null,
                    null,
                    null,
                    "android_unread_fetch_completed",
                    "Android unread API completed",
                    "api",
                    "success",
                    p,
                    null
                );

            for (int i = 0; i < messages.length(); i++) {
                JSONObject item = messages.optJSONObject(i);
                if (item == null) {
                    continue;
                }
                EncryptedMessageNotifier.notifyFromUnreadApiRecord(context, item);
            }

            return true;
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    private static boolean showFallbackNotification(Context context, @Nullable Map<String, String> payloadData) {
        if (payloadData == null || payloadData.isEmpty()) {
            return false;
        }
        return EncryptedMessageNotifier.notifyFromPushData(context, payloadData);
    }

    private static String resolveUnreadUrl(SharedPreferences prefs, @Nullable Map<String, String> payloadData) {
        if (payloadData != null) {
            String explicitUnreadUrl = firstNonEmpty(payloadData.get("unread_url"), payloadData.get("unreadUrl"));
            if (!TextUtils.isEmpty(explicitUnreadUrl)) {
                return explicitUnreadUrl;
            }

            String baseUrlFromPayload = firstNonEmpty(
                    payloadData.get("base_url"),
                    payloadData.get("baseUrl"),
                    payloadData.get("backend_url"),
                    payloadData.get("backendUrl"),
                    payloadData.get("api_base_url"),
                    payloadData.get("apiBaseUrl")
            );
            if (!TextUtils.isEmpty(baseUrlFromPayload)) {
                return joinUrl(baseUrlFromPayload, "/api/rooms/messages/unread");
            }
        }

        for (String key : BASE_URL_PREF_KEYS) {
            String value = prefs.getString(key, null);
            if (!TextUtils.isEmpty(value)) {
                return joinUrl(value, "/api/rooms/messages/unread");
            }
        }

        // Final fallback: hard-coded default base URL
        return joinUrl(DEFAULT_BASE_URL, "/api/rooms/messages/unread");
    }

    private static String joinUrl(String baseUrl, String path) {
        String normalizedBase = baseUrl.endsWith("/") ? baseUrl.substring(0, baseUrl.length() - 1) : baseUrl;
        String normalizedPath = path.startsWith("/") ? path : "/" + path;
        return normalizedBase + normalizedPath;
    }

    private static String readStream(@Nullable java.io.InputStream stream) throws Exception {
        if (stream == null) {
            return "";
        }

        StringBuilder builder = new StringBuilder();
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(stream, StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                builder.append(line);
            }
        }
        return builder.toString();
    }

    @Nullable
    private static String firstNonEmpty(@Nullable String... values) {
        if (values == null) {
            return null;
        }
        for (String value : values) {
            if (!TextUtils.isEmpty(value)) {
                return value;
            }
        }
        return null;
    }
}
