import Foundation

public enum FcmTokenRegistrar {
    /// Same `safe_storage` keys as Android (`FcmTokenRegistrar.java`).
    private static let baseUrlKeys = [
        "backendBaseUrl",
        "backend_url",
        "apiBaseUrl",
        "api_base_url",
        "serverUrl",
        "server_url"
    ]

    private static let defaultBaseUrl = "https://4.rw"
    private static let defaultFcmEndpointPath = "/api/users/fcm-token"
    private static let oneSignalEndpointPath = "/api/push/register"

    private static let requestTimeout: TimeInterval = 15

    private static func isTruthyStorageFlag(_ key: String) -> Bool {
        guard let raw = SafeStorageStore.get(key)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return raw == "true" || raw == "1" || raw == "yes"
    }

    private static func resolvedJwt() -> String? {
        let jwt = SafeStorageStore.get("token") ?? SafeStorageStore.get("authToken")
        guard let jwtToken = jwt, !jwtToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return jwtToken
    }

    private static func resolvedBaseUrl() -> String {
        for key in baseUrlKeys {
            if let value = SafeStorageStore.get(key), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return defaultBaseUrl
    }

    private static func registrationURL(base: String, path: String) -> String? {
        let normalizedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        return normalizedBase + normalizedPath
    }

    /// Stores an FCM registration token (e.g. from Firebase on iOS) in `safe_storage` and attempts backend registration.
    /// Clears `fcmTokenRegistered` when the token changes so the server is updated.
    public static func updateFcmToken(_ token: String?) {
        let normalized = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if normalized.isEmpty {
            SafeStorageStore.remove("fcmToken")
            SafeStorageStore.set("fcmTokenRegistered", value: "false")
            print("🔔 [iOS/FcmTokenRegistrar] Cleared FCM token from local storage.")
            return
        }

        let existing = SafeStorageStore.get("fcmToken")?.trimmingCharacters(in: .whitespacesAndNewlines)
        SafeStorageStore.set("fcmToken", value: normalized)
        SafeStorageStore.set("pushTokenType", value: "fcm")
        SafeStorageStore.set("pushTokenUpdatedAt", value: "\(Int(Date().timeIntervalSince1970 * 1000))")

        if existing != normalized {
            SafeStorageStore.set("fcmTokenRegistered", value: "false")
            print("🔔 [iOS/FcmTokenRegistrar] Stored new FCM token (length=\(normalized.count)).")
        }

        registerIfPossible()
    }

    public static func updateOneSignalPlayerId(_ playerId: String?) {
        let normalizedPlayerId = playerId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if normalizedPlayerId.isEmpty {
            SafeStorageStore.remove("onesignalPlayerId")
            SafeStorageStore.remove("onesignalSubscriptionId")
            SafeStorageStore.set("onesignalPlayerIdRegistered", value: "false")
            print("🔔 [iOS/FcmTokenRegistrar] Cleared OneSignal subscription id from local storage.")
            return
        }

        let existingPlayerId = SafeStorageStore.get("onesignalPlayerId")?.trimmingCharacters(in: .whitespacesAndNewlines)
        SafeStorageStore.set("onesignalPlayerId", value: normalizedPlayerId)
        SafeStorageStore.set("onesignalSubscriptionId", value: normalizedPlayerId)
        SafeStorageStore.set("pushTokenType", value: "onesignal_player_id")
        SafeStorageStore.set("pushTokenUpdatedAt", value: "\(Int(Date().timeIntervalSince1970 * 1000))")

        if existingPlayerId != normalizedPlayerId {
            SafeStorageStore.set("onesignalPlayerIdRegistered", value: "false")
            print("🔔 [iOS/FcmTokenRegistrar] Stored new OneSignal subscription id: \(normalizedPlayerId)")
        }

        registerIfPossible()
    }

    /// Registers with the backend when possible: **FCM** (`/api/users/fcm-token` or `fcmTokenEndpoint`) and/or **OneSignal** (`/api/push/register`), using the same `safe_storage` keys as Android.
    public static func registerIfPossible() {
        registerFcmTokenIfPossible()
        registerOneSignalIfPossible()
    }

    private static func registerFcmTokenIfPossible() {
        guard let fcmToken = SafeStorageStore.get("fcmToken")?.trimmingCharacters(in: .whitespacesAndNewlines), !fcmToken.isEmpty else {
            print("🔔 [iOS/FcmTokenRegistrar] No FCM token stored, skipping FCM registration.")
            return
        }

        if isTruthyStorageFlag("fcmTokenRegistered") {
            print("🔔 [iOS/FcmTokenRegistrar] FCM token already registered with server.")
            return
        }

        guard let jwtToken = resolvedJwt() else {
            print("🔔 [iOS/FcmTokenRegistrar] No JWT token yet (user not logged in); FCM registration deferred.")
            return
        }

        let base = resolvedBaseUrl()
        var path = SafeStorageStore.get("fcmTokenEndpoint")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if path.isEmpty {
            path = defaultFcmEndpointPath
        }

        guard let urlString = registrationURL(base: base, path: path), let url = URL(string: urlString) else {
            print("🔔 [iOS/FcmTokenRegistrar] Invalid FCM registration URL.")
            return
        }

        let payload: [String: Any] = ["fcmToken": fcmToken]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            print("🔔 [iOS/FcmTokenRegistrar] Failed to encode FCM registration payload.")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(jwtToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        print("🔔 [iOS/FcmTokenRegistrar] Dispatching FCM token registration to \(urlString)")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                print("🔔 [iOS/FcmTokenRegistrar] FCM registration error: \(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse else {
                print("🔔 [iOS/FcmTokenRegistrar] FCM registration failed: No HTTP response")
                return
            }
            if 200 ..< 300 ~= http.statusCode {
                print("🔔 [iOS/FcmTokenRegistrar] FCM token registered successfully (HTTP \(http.statusCode)).")
                SafeStorageStore.set("fcmTokenRegistered", value: "true")
            } else {
                let responseBody = String(data: data ?? Data(), encoding: .utf8) ?? ""
                print("🔔 [iOS/FcmTokenRegistrar] FCM registration failed (HTTP \(http.statusCode)) body=\(responseBody)")
            }
        }.resume()
    }

    private static func registerOneSignalIfPossible() {
        guard let playerId = SafeStorageStore.get("onesignalPlayerId")?.trimmingCharacters(in: .whitespacesAndNewlines), !playerId.isEmpty else {
            print("🔔 [iOS/FcmTokenRegistrar] No OneSignal subscription id stored, skipping OneSignal registration.")
            return
        }

        if isTruthyStorageFlag("onesignalPlayerIdRegistered") {
            print("🔔 [iOS/FcmTokenRegistrar] OneSignal subscription id already registered with server.")
            return
        }

        guard let jwtToken = resolvedJwt() else {
            print("🔔 [iOS/FcmTokenRegistrar] No JWT token yet (user not logged in); OneSignal registration deferred.")
            return
        }

        let base = resolvedBaseUrl()
        guard let urlString = registrationURL(base: base, path: oneSignalEndpointPath), let url = URL(string: urlString) else {
            print("🔔 [iOS/FcmTokenRegistrar] Invalid OneSignal registration URL.")
            return
        }

        let payload: [String: Any] = [
            "playerId": playerId,
            "platform": "ios"
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            print("🔔 [iOS/FcmTokenRegistrar] Failed to encode OneSignal registration payload.")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(jwtToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        print("🔔 [iOS/FcmTokenRegistrar] Dispatching OneSignal subscription registration to \(urlString)")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                print("🔔 [iOS/FcmTokenRegistrar] OneSignal registration error: \(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse else {
                print("🔔 [iOS/FcmTokenRegistrar] OneSignal registration failed: No HTTP response")
                return
            }
            if 200 ..< 300 ~= http.statusCode {
                print("🔔 [iOS/FcmTokenRegistrar] OneSignal subscription id registered successfully (HTTP \(http.statusCode)).")
                SafeStorageStore.set("onesignalPlayerIdRegistered", value: "true")
            } else {
                let responseBody = String(data: data ?? Data(), encoding: .utf8) ?? ""
                print("🔔 [iOS/FcmTokenRegistrar] OneSignal registration failed (HTTP \(http.statusCode)) body=\(responseBody)")
            }
        }.resume()
    }
}
