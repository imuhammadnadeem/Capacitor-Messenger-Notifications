# Host App Setup Guide

To fully integrate **capacitor-messenger-notifications**, you need some platform-specific configuration in your host application.

---

## 1. Android Setup

### AndroidManifest.xml

Add the following permissions and components to your `android/app/src/main/AndroidManifest.xml`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- Permissions -->
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />

    <application ...>
        <!-- The plugin service and receiver are automatically merged, 
             but ensure your app's MainActivity is set to singleTop for notification clicks -->
        <activity
            android:name=".MainActivity"
            android:launchMode="singleTop" ...>
            ...
        </activity>
    </application>
</manifest>

### ProGuard Rules (Android)
If your app has `minifyEnabled true`, add the following rules to your **`android/app/proguard-rules.pro`** to ensure Socket.IO is not stripped:

```proguard
# Socket.IO
-keep class io.socket.** { *; }
-keep class okhttp3.** { *; }
-keep class org.json.** { *; }
-dontwarn io.socket.**

# Plugin Internals
-keep class com.codecraft_studio.messenger.notifications.** { *; }
```

### build.gradle

Ensure your `v2` repositories can resolve the socket.io client. The plugin already bundles it, but adding it to the app module can help with resolution:

```groovy
dependencies {
    implementation 'io.socket:socket.io-client:2.1.0'
}
```

---

## 2. iOS Setup

### App Capabilities

Open your project in Xcode and add the following capabilities in the **"Signing & Capabilities"** tab:

1. **Push Notifications**
2. **Background Modes**:
   - **Remote notifications** (Required for `didReceiveRemoteNotification`)
   - **Background fetch**

### Info.plist (Background Fetch)

To ensure the OS permits background fetch consistently, add the following to your **`ios/App/App/Info.plist`**:

```xml
<key>UIBackgroundModes</key>
<array>
  <string>fetch</string>
  <string>remote-notification</string>
</array>
```

### AppDelegate.swift

To handle notification clicks and background pushes, update your `AppDelegate.swift`:

```swift
import Capacitor
import MessengerNotifications // Import the plugin module

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // ... (existing code)
        
        // Handle cold start from notification
        if let notification = launchOptions?[.remoteNotification] as? [String: Any],
           let roomId = notification["roomId"] as? Int {
            MessengerNotificationsPlugin.pendingRoomId = roomId
        }
        
        return true
    }

    // Handle background pushes with temporary socket session
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        
        let payload = userInfo as? [String: Any]
        TemporarySocketSessionManager.runSession(payloadData: payload) { messageReceived in
            completionHandler(messageReceived ? .newData : .noData)
        }
    }
}
```

### UNUserNotificationCenter Support

Ensure your app registers for remote notifications as part of standard Capacitor Push setup.

---

## 3. Web Setup (Optional)

The plugin provides a web implementation using standard `window.Notification` for basic fallback. No additional setup is required beyond calling `requestPermissions()`.

---

## Troubleshooting

### Android Service Killed

Ensure your app is not restricted in "Battery Optimization" on some Android skins (Samsung/Xiaomi). Foreground services require an active notification which the plugin provides.

### iOS Push Not Working

Ensure you have configured your **APNs certificates** in the Apple Developer Portal and linked them to your Firebase/Push provider.
