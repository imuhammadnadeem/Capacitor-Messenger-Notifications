import Foundation
import Capacitor
import UserNotifications

@objc(MessengerNotificationsPlugin)
public class MessengerNotificationsPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "MessengerNotificationsPlugin"
    public let jsName = "MessengerNotifications"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "showNotification", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearRoomNotification", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getPendingRoomId", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startPersistentSocket", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopPersistentSocket", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "checkPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "registerFcmToken", returnType: CAPPluginReturnPromise)
    ]

    /// Set from native notification tap handling (e.g. AppDelegate) so JS can read via `getPendingRoomId`.
    public static var pendingRoomId: Int?

    @objc func showNotification(_ call: CAPPluginCall) {
        let title = call.getString("title") ?? "New Message"
        let body = call.getString("body") ?? "You have a new message"
        let roomId = call.getInt("roomId") ?? 0
        let messageId = call.getString("messageId")
        let timestamp = call.getInt("timestamp") ?? 0

        _ = NotificationHelper.showRoomNotification(
            title: title,
            body: body,
            roomId: roomId,
            messageId: messageId,
            timestamp: Int64(timestamp),
            isSync: false
        )
        call.resolve()
    }

    @objc func clearRoomNotification(_ call: CAPPluginCall) {
        let roomId = call.getInt("roomId") ?? 0
        if roomId > 0 {
            NotificationHelper.clearRoomHistory(roomId: roomId, cancelNotification: true)
        }
        call.resolve()
    }

    @objc func getPendingRoomId(_ call: CAPPluginCall) {
        if let rid = MessengerNotificationsPlugin.pendingRoomId {
            call.resolve(["roomId": rid])
            MessengerNotificationsPlugin.pendingRoomId = nil
        } else {
            call.resolve(["roomId": NSNull()])
        }
    }

    @objc func startPersistentSocket(_ call: CAPPluginCall) {
        guard let url = call.getString("url"), let token = call.getString("token") else {
            call.reject("Missing URL or token")
            return
        }

        SafeStorageStore.set("socketUrl", value: url)
        SafeStorageStore.set("token", value: token)

        call.resolve()
    }

    @objc func stopPersistentSocket(_ call: CAPPluginCall) {
        call.resolve()
    }

    @objc func checkPermissions(_ call: CAPPluginCall) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let state: String
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                state = "granted"
            case .denied:
                state = "denied"
            case .notDetermined:
                state = "prompt"
            @unknown default:
                state = "prompt"
            }
            call.resolve(["notifications": state])
        }
    }

    @objc func requestPermissions(_ call: CAPPluginCall) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                call.reject(error.localizedDescription)
                return
            }
            call.resolve(["notifications": granted ? "granted" : "denied"])
        }
    }

    @objc func registerFcmToken(_ call: CAPPluginCall) {
        FcmTokenRegistrar.registerIfPossible()
        call.resolve()
    }
}
