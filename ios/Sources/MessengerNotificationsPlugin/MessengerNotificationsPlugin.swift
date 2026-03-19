import Foundation
import Capacitor

@objc(MessengerNotificationsPlugin)
public class MessengerNotificationsPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "MessengerNotificationsPlugin"
    public let jsName = "MessengerNotifications"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "showNotification", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearRoomNotification", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getPendingRoomId", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startPersistentSocket", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopPersistentSocket", returnType: CAPPluginReturnPromise)
    ]

    private static var _pendingRoomId: Int? = nil
    public static var pendingRoomId: Int? {
        get { return _pendingRoomId }
        set { _pendingRoomId = newValue }
    }

    @objc func showNotification(_ call: CAPPluginCall) {
        let title = call.getString("title") ?? "New Message"
        let body = call.getString("body") ?? "You have a new message"
        let roomId = call.getInt("roomId") ?? 0
        let messageId = call.getString("messageId")
        let timestamp = call.getInt("timestamp") ?? 0
        let roomName = call.getString("roomName")

        NotificationHelper.showRoomNotification(
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
            NotificationHelper.clearRoomHistory(roomId: roomId)
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
        
        // On iOS, persistent sockets are usually handled differently (or not at all in same way as Android service)
        // because of background limits. But for now we'll store them.
        SafeStorageStore.set("socket_url", value: url)
        SafeStorageStore.set("auth_token", value: token)
        
        // We'll call complete for now.
        call.resolve()
    }

    @objc func stopPersistentSocket(_ call: CAPPluginCall) {
        call.resolve()
    }
}
