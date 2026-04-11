package com.codecraft_studio.messenger.notifications;

import android.content.Context;
import android.content.SharedPreferences;
import android.text.TextUtils;
import android.util.Log;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Registers the device's FCM token with the backend API.
 *
 * SharedPreferences keys used (all in "safe_storage"):
 *   fcmToken            – the raw FCM registration token
 *   fcmTokenRegistered  – boolean; true once ACKed by the server
 *   token / authToken   – the user's JWT
 *   backendBaseUrl / backend_url / apiBaseUrl / api_base_url / serverUrl / server_url
 *                       – base URL of the backend
 *   fcmTokenEndpoint    – optional override for the registration endpoint path
 */
final class FcmTokenRegistrar {

    private static final String TAG = "FcmTokenRegistrar";
    private static final String PREFS_NAME = "safe_storage";
    private static final String DEFAULT_ENDPOINT_PATH = "/api/users/fcm-token";
    private static final int CONNECT_TIMEOUT_MS = 8_000;
    private static final int READ_TIMEOUT_MS = 10_000;

    private static final List<String> BASE_URL_KEYS = Arrays.asList(
        "backendBaseUrl",
        "backend_url",
        "apiBaseUrl",
        "api_base_url",
        "serverUrl",
        "server_url"
    );

    private static final ExecutorService EXECUTOR = Executors.newSingleThreadExecutor();

    private FcmTokenRegistrar() {}

    static void registerIfPossible(Context context) {
        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);

        String fcmToken = prefs.getString("fcmToken", null);
        if (TextUtils.isEmpty(fcmToken)) {
            Log.d(TAG, "No FCM token stored, skipping registration.");
            return;
        }

        boolean alreadyRegistered = prefs.getBoolean("fcmTokenRegistered", false);
        if (alreadyRegistered) {
            Log.d(TAG, "FCM token already registered with server.");
            return;
        }

        String jwtToken = firstNonEmpty(prefs.getString("token", null), prefs.getString("authToken", null));
        if (TextUtils.isEmpty(jwtToken)) {
            Log.d(TAG, "No JWT token yet (user not logged in). JS will register token after login.");
            return;
        }

        String baseUrl = null;
        for (String key : BASE_URL_KEYS) {
            String v = prefs.getString(key, null);
            if (!TextUtils.isEmpty(v)) {
                baseUrl = v;
                break;
            }
        }
        if (TextUtils.isEmpty(baseUrl)) {
            Log.w(TAG, "No backend base URL configured, cannot register FCM token.");
            return;
        }

        final String finalFcmToken = fcmToken;
        final String finalJwtToken = jwtToken;
        final String registrationUrl = buildUrl(prefs, baseUrl);
        final Context appContext = context.getApplicationContext();

        Log.i(TAG, "Dispatching FCM token registration to " + registrationUrl);
        EXECUTOR.execute(() -> doRegister(appContext, finalFcmToken, finalJwtToken, registrationUrl));
    }

    private static void doRegister(Context context, String fcmToken, String jwtToken, String url) {
        HttpURLConnection conn = null;
        try {
            byte[] body = ("{\"fcmToken\":\"" + fcmToken + "\"}").getBytes(StandardCharsets.UTF_8);

            conn = (HttpURLConnection) new URL(url).openConnection();
            conn.setRequestMethod("POST");
            conn.setConnectTimeout(CONNECT_TIMEOUT_MS);
            conn.setReadTimeout(READ_TIMEOUT_MS);
            conn.setDoOutput(true);
            conn.setRequestProperty("Authorization", "Bearer " + jwtToken);
            conn.setRequestProperty("Content-Type", "application/json");
            conn.setRequestProperty("Accept", "application/json");
            conn.setFixedLengthStreamingMode(body.length);

            try (OutputStream os = conn.getOutputStream()) {
                os.write(body);
            }

            int status = conn.getResponseCode();
            if (status >= 200 && status < 300) {
                Log.i(TAG, "FCM token registered successfully (HTTP " + status + ").");
                context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit().putBoolean("fcmTokenRegistered", true).apply();
            } else {
                Log.w(TAG, "FCM token registration failed (HTTP " + status + "). Will retry.");
            }
        } catch (Exception e) {
            Log.w(TAG, "FCM token registration error – will retry next time.", e);
        } finally {
            if (conn != null) {
                conn.disconnect();
            }
        }
    }

    private static String buildUrl(SharedPreferences prefs, String baseUrl) {
        String endpointPath = prefs.getString("fcmTokenEndpoint", DEFAULT_ENDPOINT_PATH);
        if (TextUtils.isEmpty(endpointPath)) {
            endpointPath = DEFAULT_ENDPOINT_PATH;
        }
        String normalizedBase = baseUrl.endsWith("/") ? baseUrl.substring(0, baseUrl.length() - 1) : baseUrl;
        String normalizedPath = endpointPath.startsWith("/") ? endpointPath : "/" + endpointPath;
        return normalizedBase + normalizedPath;
    }

    private static String firstNonEmpty(String... values) {
        for (String v : values) {
            if (!TextUtils.isEmpty(v)) return v;
        }
        return null;
    }
}
