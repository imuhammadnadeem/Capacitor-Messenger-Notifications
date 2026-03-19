# Contributing

This project is a Capacitor plugin for managing messenger-style notifications.

## Development

1. **Install Dependencies**: `npm install`
2. **Build Plugin**: `npm run build`
3. **Verify Platforms**:
   - iOS: `npm run verify:ios`
   - Android: `npm run verify:android`
4. **Lint and Format**: `npm run lint`

## Adding Features

This plugin is designed to combine native notification logic from **ChatE2EE** systems. When adding features, ensure they maintain cross-platform behavior where possible.

### Android Service

The `PersistentSocketService` is a foreground service. Ensure you use appropriate permissions and a notification to avoid it being killed by the system.

### iOS Temporary Sessions

Background execution on iOS is highly restricted. Always keep the `TemporarySocketSessionManager` tasks short and call the `completionHandler` promptly.
