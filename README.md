# capacitor-messenger-notifications

[![license](https://img.shields.io/npm/l/capacitor-messenger-notifications.svg)](https://github.com/codecraft-studio/capacitor-messenger-notifications/blob/main/LICENSE)

Capacitor plugin for managing messenger-style notifications with WebSocket support on Android and iOS. Built for end-to-end encrypted chat applications.

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Install](#install)
- [Usage](#usage)
  - [JavaScript Examples](#javascript-examples)
  - [Native Integration (Android/iOS)](#native-integration-androidios)
- [Configuration](#configuration)
- [Platform Implementation](#platform-implementation)
- [Setup by Platform](#setup-by-platform)
- [API](#api)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [Contributing](#contributing)
- [License](#license)

## Features

- **Native Notification Grouping**: Automatically groups messages by room ID using `MessagingStyle` (Android) and `threadIdentifier` (iOS).
- **Persistent WebSocket (Android)**: Foreground service that stays alive to receive messages even when the app is killed.
- **Background Fetch (iOS)**: Automatically wakes up to fetch unread messages when a silent push is received.
- **End-to-End Encryption Ready**: Designed to handle encrypted payloads and decrypt them on-device before showing notifications.

## Requirements

- **Capacitor**: ^6.0.0 || ^7.0.0 || ^8.0.0
- **Node.js**: 18.x or higher
- **iOS**: 13.0 or higher
- **Android**: API level 22 (Android 5.1) or higher

## Install

```bash
npm install capacitor-messenger-notifications
npx cap sync
```

## Usage

### JavaScript Examples

#### Start Persistent Socket (Android)

```typescript
import { MessengerNotifications } from 'capacitor-messenger-notifications';

// Starts a foreground service on Android to maintain a heartbeat connection
await MessengerNotifications.startPersistentSocket({
  url: 'wss://your-chat-server.com',
  token: 'YOUR_AUTH_TOKEN'
});
```

#### Show a Manual Notification

```typescript
await MessengerNotifications.showNotification({
  title: 'John Doe',
  body: 'Hey, how are you?',
  roomId: 101,
  roomName: 'General Chat',
  messageId: 'uuid-12345',
  timestamp: Date.now()
});
```

### Native Integration (Android/iOS)

This plugin is often triggered from native background tasks (FCM / Silent Push).

- **Android**: Use `EncryptedMessageNotifier.notifyFromSocketPayload(context, data)` from your background services.
- **iOS**: Use `TemporarySocketSessionManager.shared.fetchAndNotify(...)` inside `didReceiveRemoteNotification`.

## Configuration

Most configurations are handled dynamically via the API, but you can define defaults in **`capacitor.config.json`**:

```json
{
  "plugins": {
    "MessengerNotifications": {
      "defaultSocketUrl": "wss://your-default-server.com",
      "notificationChannelId": "chat_messages",
      "notificationChannelName": "Messenger Notifications"
    }
  }
}
```

## Platform Implementation

| Platform | Implementation |
| --- | --- |
| Android | Foreground Service + NotificationManager with `MessagingStyle`. |
| iOS | `UNNotificationContent` with `threadIdentifier` + SocketIO Task. |

## Setup by Platform

> For full host‑app steps (Android & iOS), see `HOST_APP_SETUP.md`.

### Android

- **AndroidManifest.xml**: Add `FOREGROUND_SERVICE` and `POST_NOTIFICATIONS` permissions.
- **ProGuard**: Add `-keep` rules for the plugin and Socket.IO.

### iOS

- **Capabilities**: Enable **Push Notifications** and **Background Modes** (Background fetch, Remote notifications).

## API

| Method | Description |
| --- | --- |
| `startPersistentSocket(options)` | Starts the background socket service (Android only). |
| `stopPersistentSocket()` | Stops the background socket service. |
| `showNotification(options)` | Manually triggers a native grouped notification. |
| `clearRoomNotification(options)` | Clears all notifications for a specific room. |
| `getPendingRoomId()` | Returns the roomId if the app was launched from a notification. |

---

## Troubleshooting

### Android: Service is killed

Ensure you have added `android:foregroundServiceType="dataSync"` to the service declaration in `AndroidManifest.xml` as required by Android 14+.

### iOS: Notifications aren't grouping

Ensure `threadIdentifier` is correctly set in the push payload or that you are passing the same `roomId` to `showNotification`.

## Development

- **Build**: `npm run build`
- **Lint**: `npm run lint`
- **Format**: `npm run fmt`
- **Verify**: `npm run verify`

## Contributing

Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## License

MIT
