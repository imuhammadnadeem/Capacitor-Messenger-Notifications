# capacitor-messenger-notifications

[![license](https://img.shields.io/npm/l/capacitor-messenger-notifications.svg)](https://github.com/imuhammadnadeem/capacitor-messenger-notifications/blob/main/LICENSE)

Capacitor plugin for managing messenger-style notifications with WebSocket support on Android and iOS. Built for end-to-end encrypted chat applications.

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Install](#install)
- [Usage](#usage)
  - [Permissions](#permissions)
  - [Show a Notification](#show-a-notification)
  - [Clear a Room's Notifications](#clear-a-rooms-notifications)
  - [Cold-Start Navigation](#cold-start-navigation)
  - [Persistent Socket (Android)](#persistent-socket-android)
  - [Push token / OneSignal registration](#push-token--onesignal-registration)
  - [Native Integration](#native-integration)
- [Setup by Platform](#setup-by-platform)
  - [Android](#android)
  - [iOS](#ios)
- [How It Works](#how-it-works)
- [API](#api)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [Contributing](#contributing)
- [License](#license)

---

## Features

- **Native Notification Grouping**: Groups messages per room using `MessagingStyle` (Android) and `threadIdentifier` (iOS), keyed dynamically off the host app's package/bundle ID.
- **End-to-End Decryption**: Decrypts room names, usernames, and message bodies on-device using Libsodium (Android) and swift-sodium (iOS) before showing any notification.
- **Persistent WebSocket (Android)**: A foreground service maintains a live Socket.IO connection for devices without Google Play Services (GMS), auto-reconnecting on token or network changes.
- **FCM Background Fetch (Android)**: On GMS devices, `FcmFetchForegroundService` + `FcmFetchBackgroundService` spin up a short-lived socket session triggered by each FCM push and tear it down cleanly.
- **Job Scheduler Retry (Android)**: `FcmJobService` schedules a retry via `JobScheduler` if the primary fetch fails, ensuring no message is dropped.
- **Background Fetch (iOS)**: `TemporarySocketSessionManager` opens a short-lived Socket.IO session inside `didReceiveRemoteNotification` with idle and max-session timeouts.
- **HTTP Unread Fallback**: Both platforms fall back to fetching from the `/api/rooms/messages/unread` endpoint when a socket session cannot decrypt a message.
- **Rich Notifications**: Custom SVG avatar rendering (Android via AndroidSVG), conversation shortcuts, and dismissal tracking.
- **Notification Deduplication**: In-memory + persisted message ID tracking prevents showing the same message twice across socket and FCM paths.
- **Dynamic Resources**: All icon, app name, and notification group key lookups are resolved from the host app at runtime — no hardcoded app-specific values.
- **`window.Notification` Polyfill (Android)**: Injects a polyfill into the WebView so the JS app's `new Notification(...)` calls route through the native plugin.
- **Push registration**: **Android** — registers the FCM token via `POST …/api/users/fcm-token` (or your `fcmTokenEndpoint` override). **iOS** — can register **both**: FCM token to the same endpoint when `fcmToken` is in `safe_storage` (e.g. from Firebase), and the OneSignal subscription id via `POST …/api/push/register` when `onesignalPlayerId` is set (`FcmTokenRegistrar.updateOneSignalPlayerId(_:)` / `updateFcmToken(_:)`).
- **Message flow logging (optional)**: **Android** — `MessageFlowLogger` POSTs structured steps to `{backend}/api/message-flow-logs/ingest`. **iOS** — `MessageFlowLogger` in the plugin sends the same style of events over HTTPS.
- **App Group storage (iOS)**: `SafeStorageStore` can mirror `safe_storage` into a shared App Group when you set the `MessengerNotificationsAppGroup` key in Info.plist (for extensions / NSE).

---

## Requirements

- **Capacitor**: ^6.0.0 || ^7.0.0 || ^8.0.0
- **Node.js**: 18.x or higher
- **iOS**: 13.0 or higher
- **Android**: API level 22 (Android 5.1) or higher

---

## Install

```bash
npm install capacitor-messenger-notifications
npx cap sync
```

---

## Usage

### Permissions

Before showing notifications, check and request permission:

```typescript
import { MessengerNotifications } from 'capacitor-messenger-notifications';

const status = await MessengerNotifications.checkPermissions();

if (status.notifications !== 'granted') {
  const result = await MessengerNotifications.requestPermissions();
  if (result.notifications !== 'granted') {
    console.warn('Notification permission denied');
  }
}
```

### Show a Notification

```typescript
await MessengerNotifications.showNotification({
  title: 'Alice',
  body: 'Hey, how are you?',
  roomId: 101,
  roomName: 'General Chat',
  messageId: 'uuid-12345',
  timestamp: Date.now(),
  senderId: 42,
  avatarSvg: '<svg>...</svg>', // optional SVG string for sender avatar
});
```

### Clear a Room's Notifications

```typescript
await MessengerNotifications.clearRoomNotification({ roomId: 101 });
```

### Cold-Start Navigation

Notification tap intents include a `roomId` extra on Android. The plugin exposes `getPendingRoomId()` for JS; on **Android** you should also forward the launch intent room into native storage if you use a custom activity, e.g. `NotificationHelper.setPendingRoomId(roomId)` when handling `onNewIntent` / `onCreate`. On **iOS**, set `MessengerNotificationsPlugin.pendingRoomId = roomId` from your `AppDelegate` / OneSignal click handler when the user opens a chat from a notification.

```typescript
const { roomId } = await MessengerNotifications.getPendingRoomId();
if (roomId !== null) {
  router.push(`/room/${roomId}`);
}
```

### Persistent Socket (Android)

On non-GMS Android devices the plugin starts a foreground service that keeps a Socket.IO connection alive. Call this after the user logs in:

```typescript
await MessengerNotifications.startPersistentSocket({
  url: 'wss://your-chat-server.com',
  token: 'YOUR_AUTH_JWT',
});

// Call when the user logs out
await MessengerNotifications.stopPersistentSocket();
```

> On GMS devices the socket is only opened for the duration of each incoming FCM push. `startPersistentSocket` stores the credentials but does not start the service.

### Push token / OneSignal registration

After the user logs in, call:

```typescript
await MessengerNotifications.registerFcmToken();
```

- **Android**: Reads `fcmToken`, JWT, and backend URL from `safe_storage`, then `POST {base}/api/users/fcm-token` with `{ "fcmToken": "..." }` (or your `fcmTokenEndpoint` override). Skips when `fcmTokenRegistered` is already true.
- **iOS**: Runs **both** registrations when the prerequisites exist (each is independent). **FCM**: `fcmToken` + JWT + base URL → `POST {base}/api/users/fcm-token` (or `fcmTokenEndpoint`); skips when `fcmTokenRegistered` is true. **OneSignal**: `onesignalPlayerId` + JWT + base URL → `POST {base}/api/push/register` with `{ "playerId": "...", "platform": "ios" }`; skips when `onesignalPlayerIdRegistered` is true. From Swift use `FcmTokenRegistrar.updateFcmToken(_:)` / `updateOneSignalPlayerId(_:)` when tokens change.

### Native Integration

The plugin is typically triggered from native background handlers:

**Android** — Inside your `FirebaseMessagingService.onMessageReceived`:

```java
// Kicks off the full fetch → decrypt → notify pipeline
FcmFetchManager.retrieveMessages(context, remoteMessage.getData());
```

**iOS** — Inside `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`:

```swift
EncryptedMessageNotifier.notifyFromPushData(userInfo as? [String: Any] ?? [:])
```

---

## Setup by Platform

### Android

#### 1. Safe Storage Keys

The plugin reads credentials from `SharedPreferences` file `"safe_storage"`. Your JS app should write the following keys (e.g. via a SafeStorage plugin):

| Key | Description |
| --- | --- |
| `token` / `authToken` | User's JWT for socket auth and API calls |
| `socketUrl` | WebSocket server URL |
| `backendBaseUrl` / `serverUrl` / ... | HTTP base URL for the unread messages API |
| `fcmToken` | FCM registration token (written by Firebase) |
| `fcmTokenRegistered` | Set by the plugin to true after a successful `POST` to the FCM endpoint |
| `fcmTokenEndpoint` | Optional path override (default `/api/users/fcm-token`) |
| `roomDecryptedKeys` | JSON map of room E2EE private keys |
| `memberDecryptedKeys` | JSON map of member E2EE private keys |

#### 2. Required Resources

Add the following drawables to your host app's `res/drawable/` so the plugin can find them at runtime (fallback to system icons if absent):

| Resource | Purpose |
| --- | --- |
| `ic_notification.png` | Small notification icon (monochrome, white on transparent) |
| `ic_transparent.png` | Transparent icon for the persistent service notification |

#### 3. AndroidManifest.xml

The plugin's manifest already declares all necessary services and permissions. If you need to override, merge the following into your app's manifest:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.WAKE_LOCK" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
```

#### 4. ProGuard

Add to your `proguard-rules.pro`:

```proguard
-keep class com.codecraft_studio.messenger.notifications.** { *; }
-keep class io.socket.** { *; }
-keep class org.java_websocket.** { *; }
```

---

### iOS

#### 1. Capabilities

In Xcode, enable the following for your app target:

- **Push Notifications**
- **Background Modes** → check *Remote notifications* and *Background fetch*

#### 2. Info.plist (App Group, optional)

If you use a Notification Service Extension or shared storage with the main app, set your App Group identifier:

```xml
<key>MessengerNotificationsAppGroup</key>
<string>group.your.bundle.app</string>
```

If omitted, the plugin uses only `UserDefaults.standard` for the `safe_storage` dictionary.

#### 3. AppDelegate

Forward remote notifications to the plugin when you handle data/silent payloads. When the user taps a notification and you know the `roomId`, assign `MessengerNotificationsPlugin.pendingRoomId = roomId` so JavaScript can read it via `getPendingRoomId()`.

```swift
import UIKit
import Capacitor

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let data = userInfo as? [String: Any] ?? [:]
        let handled = EncryptedMessageNotifier.notifyFromPushData(data)
        completionHandler(handled ? .newData : .noData)
    }
}
```

#### 4. Safe Storage Keys

The plugin reads from `UserDefaults` suite `"safe_storage"` (and mirrors to the App Group suite when configured). Write the following keys from your JS app:

| Key | Description |
| --- | --- |
| `token` / `authToken` | User's JWT |
| `socketUrl` | WebSocket server URL |
| `backendBaseUrl` / `serverUrl` / ... | HTTP base URL |
| `onesignalPlayerId` / `onesignalSubscriptionId` | OneSignal subscription id (`POST /api/push/register`) |
| `onesignalPlayerIdRegistered` | `"true"` after OneSignal id is ACKed by your backend (plugin sets this) |
| `fcmToken` | FCM registration token from Firebase (optional; `POST /api/users/fcm-token` same as Android) |
| `fcmTokenRegistered` | `"true"` after FCM token is ACKed (plugin sets this) |
| `fcmTokenEndpoint` | Optional path override for FCM registration (default `/api/users/fcm-token`) |
| `roomDecryptedKeys` | JSON map of room E2EE private keys |
| `memberDecryptedKeys` | JSON map of member E2EE private keys |

---

## How It Works

### Message Flow (Android)

```text
FCM push received
       │
       ▼
FcmFetchManager.retrieveMessages()
       │
       ├─► FcmFetchForegroundService  (keep process alive + wake lock)
       │
       ├─► TemporarySocketSessionManager.runSession()
       │         └─► socket.emit("sync_messages")
       │              └─► EncryptedMessageNotifier.notifyFromSyncMessagesResponse()
       │                       └─► NativeCrypto.decrypt*()
       │                              └─► NotificationHelper.showRoomNotification()
       │
       └─► [fallback] UnreadMessagesFetcher.fetchAndNotify()  (HTTP API)
```

### Message Flow (iOS)

```text
Silent push received
       │
       ▼
EncryptedMessageNotifier.notifyFromPushData()
       │
       ├─► Direct decrypt from push payload
       │
       └─► [fallback] TemporarySocketSessionManager.runSession()
                  └─► UnreadMessagesFetcher.fetchAndNotify()  (HTTP API)
```

---

## API

### `showNotification(options)`

Shows a native grouped chat notification.

| Option      | Type     | Required | Description                                                |
| ----------- | -------- | -------- | ---------------------------------------------------------- |
| `title`     | `string` | ✓        | Sender name displayed in the notification                  |
| `body`      | `string` | ✓        | Message body                                               |
| `roomId`    | `number` | ✓        | Room identifier used for grouping                          |
| `messageId` | `string` |          | Unique message ID for deduplication                        |
| `timestamp` | `number` |          | Unix timestamp (ms) for message ordering                   |
| `roomName`  | `string` |          | Room display name shown in notification subtitle           |
| `senderId`  | `number` |          | Sender's user ID (used for avatar/Person identity)         |
| `avatarSvg` | `string` |          | SVG string for the sender's avatar                         |

---

### `clearRoomNotification(options)`

Cancels all active notifications for a room and clears its in-memory history.

| Option   | Type     | Required | Description                                  |
| -------- | -------- | -------- | -------------------------------------------- |
| `roomId` | `number` | ✓        | Room whose notifications should be cleared   |

---

### `getPendingRoomId()`

Returns the `roomId` from the notification that launched the app (cold start), then clears it. Returns `{ roomId: null }` if the app was not opened via a notification.

---

### `startPersistentSocket(options)`

Stores socket credentials and starts the persistent foreground service on non-GMS Android devices.

| Option  | Type     | Required | Description          |
| ------- | -------- | -------- | -------------------- |
| `url`   | `string` | ✓        | WebSocket server URL |
| `token` | `string` | ✓        | JWT auth token       |

---

### `stopPersistentSocket()`

Stops the persistent socket foreground service.

---

### `checkPermissions()`

Returns the current notification permission state.

**Returns**: `Promise<{ notifications: 'granted' | 'denied' | 'prompt' }>`

---

### `requestPermissions()`

Prompts the user for notification permission.

**Returns**: `Promise<{ notifications: 'granted' | 'denied' | 'prompt' }>`

---

### `registerFcmToken()`

**Android**: Registers `fcmToken` with `{base}/api/users/fcm-token` (or `fcmTokenEndpoint`). **iOS**: Registers **FCM** (`fcmToken` → same endpoint/shape as Android) and **OneSignal** (`onesignalPlayerId` → `{base}/api/push/register`) when each is present and not yet marked registered. Reads JWT and backend URL from `safe_storage`.

---

## Troubleshooting

### Android: Notifications not appearing after FCM push

1. Confirm `roomDecryptedKeys` and `memberDecryptedKeys` are written to `safe_storage` before the push arrives.
2. Check Logcat for `EncryptedMessageNotifier`, `NativeCrypto`, and `NotificationHelper` tags.
3. Ensure `ic_notification` drawable exists in the host app (required for the notification icon).

### Android: Persistent service is killed

Ensure `android:foregroundServiceType="dataSync"` is declared on `PersistentSocketService` (already set in the plugin manifest). On Android 14+ the system enforces this.

### Android: Duplicate notifications

The plugin deduplicates by `messageId`. Ensure each message has a unique, stable `messageId` in the FCM payload.

### iOS: Notifications not grouping

Confirm the same `roomId` is passed to `showNotification` and that Background Modes are enabled for the app target in Xcode.

### iOS: Decryption failing

Ensure `roomDecryptedKeys` and `memberDecryptedKeys` are present in `UserDefaults` suite `"safe_storage"` before the silent push arrives.

---

## Development

```bash
npm run build    # compile TypeScript
npm run lint     # run ESLint
npm run fmt      # run Prettier
npm run verify   # build + lint + native checks
```

---

## Contributing

Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details.

---

## License

MIT
