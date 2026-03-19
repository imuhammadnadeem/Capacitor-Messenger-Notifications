# capacitor-messenger-notifications

Capacitor plugin for managing messenger-style notifications with WebSocket support on Android and iOS. Built for end-to-end encrypted chat applications.

## Features

- **Native Notification Grouping**: Automatically groups notifications by Room ID using `MessagingStyle` on Android and `threadIdentifier` on iOS.
- **Persistent WebSocket (Android)**: Foreground service that maintains a persistent connection to receive messages even when the app is in the background or killed.
- **Background Fetch (iOS)**: Spin up temporary socket sessions on push notification arrival to retrieve unread messages.
- **Smart Deduplication**: Prevents duplicate notifications by tracking recently shown message IDs and room updates.
- **Cold Start Support**: Retrieve the `roomId` that launched the app from a notification click.

## Installation

```bash
npm install capacitor-messenger-notifications
npx cap sync
```

## Quick Start

### 1. Register the Plugin

```typescript
import { MessengerNotifications } from 'capacitor-messenger-notifications';

// Request permissions
await MessengerNotifications.requestPermissions();

// Check for app launch via notification (Cold Start)
const { roomId } = await MessengerNotifications.getPendingRoomId();
if (roomId) {
  console.log('App launched from notification for room:', roomId);
}
```

### 2. Manage Socket Connection (Android Background)

```typescript
// Start the persistent foreground service on Android
await MessengerNotifications.startPersistentSocket({
  url: 'wss://your-socket-server.com',
  token: 'YOUR_AUTH_TOKEN'
});

// Stop the service (e.g. on logout)
await MessengerNotifications.stopPersistentSocket();
```

### 3. Show Manual Notifications

```typescript
await MessengerNotifications.showNotification({
  title: 'John Doe',
  body: 'Hey, how are you?',
  roomId: 123,
  roomName: 'General Chat', // Optional
  messageId: 'msg_001',      // Optional for deduplication
  timestamp: Date.now()     // Optional
});
```

## Configuration

Most configurations for this plugin are handled dynamically at runtime via the API. However, you can also define default values in your **`capacitor.config.json`** for cleaner code:

```json
{
  "plugins": {
    "MessengerNotifications": {
      "defaultSocketUrl": "wss://your-default-server.com",
      "notificationChannelId": "my_custom_channel",
      "notificationChannelName": "My Messenger Notifications"
    }
  }
}
```

*Note: Dynamically provided values in `startPersistentSocket` or `showNotification` will always take precedence over static configurations.*

### Android Configuration Details

- **Channel ID**: Defaults to `chat_messages`.
- **Foreground Service**: Always runs with a persistent notification to ensure the socket stays alive.

### iOS Configuration Details

- **Background Fetch**: Depends on the OS's internal scheduling. High-priority pushes are recommended to trigger the `TemporarySocketSessionManager` immediately.

## API

| Method | Description |
| :--- | :--- |
| `showNotification(options)` | Shows a native notification, grouped by room. |
| `clearRoomNotification({ roomId })` | Clears notifications for a specific room. |
| `getPendingRoomId()` | Returns the `roomId` that triggered the app launch. |
| `startPersistentSocket(options)` | Starts the Android foreground socket service. |
| `stopPersistentSocket()` | Stops the background service. |
| `checkPermissions()` | Checks notification permissions. |
| `requestPermissions()` | Requests notification permissions. |

## Platform Setup

For detailed platform-specific configuration (Permissions, Background Modes, AppDelegate), see [HOST_APP_SETUP.md](HOST_APP_SETUP.md).

## License

MIT
