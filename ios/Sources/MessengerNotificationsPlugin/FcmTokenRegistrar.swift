import Foundation

public enum FcmTokenRegistrar {
    private static let baseUrlKeys = [
        "backendBaseUrl",
        "backend_url",
        "apiBaseUrl",
        "api_base_url",
        "serverUrl",
        "server_url"
    ]

    private static let defaultBaseUrl = "https://4.rw"
    private static let endpointPath = "/api/push/register"

    public static func registerIfPossible() {
        guard let fcmToken = SafeStorageStore.get("fcmToken"), !fcmToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("🔔 [iOS/FcmTokenRegistrar] No FCM token stored, skipping registration.")
            return
        }

        if (SafeStorageStore.get("fcmTokenRegistered") ?? "").lowercased() == "true" {
            print("🔔 [iOS/FcmTokenRegistrar] FCM token already registered with server.")
            return
        }

        let jwt = SafeStorageStore.get("token") ?? SafeStorageStore.get("authToken")
        guard let jwtToken = jwt, !jwtToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("🔔 [iOS/FcmTokenRegistrar] No JWT token yet (user not logged in).")
            return
        }

        var baseUrl: String?
        for key in baseUrlKeys {
            if let value = SafeStorageStore.get(key), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                baseUrl = value
                break
            }
        }
        let base = baseUrl ?? defaultBaseUrl

        let urlString: String = {
            let normalizedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
            let normalizedPath = endpointPath.hasPrefix("/") ? endpointPath : "/" + endpointPath
            return normalizedBase + normalizedPath
        }()

        guard let url = URL(string: urlString) else {
            print("🔔 [iOS/FcmTokenRegistrar] Invalid registration URL: \(urlString)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(jwtToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let payload: [String: Any] = [
            "token": fcmToken,
            "platform": "ios"
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            if let jsonString = String(data: request.httpBody ?? Data(), encoding: .utf8) {
                print("🔔 [iOS/FcmTokenRegistrar] Registration payload=\(jsonString)")
            }
        } catch {
            print("🔔 [iOS/FcmTokenRegistrar] Failed to encode registration payload: \(error.localizedDescription)")
            return
        }

        print("🔔 [iOS/FcmTokenRegistrar] Dispatching FCM token registration to \(urlString)")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                print("🔔 [iOS/FcmTokenRegistrar] Registration error: \(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse else {
                print("🔔 [iOS/FcmTokenRegistrar] Registration failed: No HTTP response")
                return
            }
            if 200 ..< 300 ~= http.statusCode {
                print("🔔 [iOS/FcmTokenRegistrar] FCM token registered successfully (HTTP \(http.statusCode)).")
                SafeStorageStore.set("fcmTokenRegistered", value: "true")
            } else {
                let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
                print("🔔 [iOS/FcmTokenRegistrar] Registration failed (HTTP \(http.statusCode)) body=\(body)")
            }
        }.resume()
    }
}
