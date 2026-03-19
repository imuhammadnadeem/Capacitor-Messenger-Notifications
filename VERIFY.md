# How to verify the plugin

Run these from the **project root**.

## Quick reference

| Goal              | Command                                                                        |
| ----------------- | ------------------------------------------------------------------------------ |
| All platforms     | `npm run verify`                                                               |
| Web only          | `npm run verify:web`                                                           |
| Android only      | `npm run verify:android`                                                       |
| iOS only          | `npm run verify:ios`                                                           |

- **verify** – Builds the plugin for all platforms (Web, Android, and iOS) to ensure code integrity and dependency resolution.

---

## Web

### Web build

```bash
npm run build
```

Compiles `src/` to `dist/` using the TypeScript compiler. If this passes, the Web implementation and types are valid.

---

## Android

### Android build

```bash
npm run verify:android
```

or:

```bash
cd android && ./gradlew clean build test && cd ..
```

- **Verification**: This ensures the Java source files compile against the `@capacitor/android` dependency and that local Gradle tasks (like linting) pass.
- **Troubleshooting**: If you see missing Gradle errors, run `npm install` at the root first to ensure `@capacitor/android` is present in `node_modules`.

---

## iOS

Capacitor plugins use **xcodebuild** for verification from the command line.

### Command line (CI)

```bash
npm run verify:ios
```

or:

```bash
xcodebuild -scheme MessengerNotifications -destination 'generic/platform=iOS' -configuration Debug build
```

- **SPM Support**: This uses the `Package.swift` at the root. If the scheme is not found, run `xcodebuild -list` once to refresh the package graph.
- **Simulator build**: To build for a specific simulator:

  ```bash
  xcodebuild -scheme MessengerNotifications -destination 'platform=iOS Simulator,name=iPhone 15' build
  ```

### Xcode (GUI)

1. Open **Package.swift** in Xcode.
2. Select the **MessengerNotifications** scheme.
3. Build with **Cmd+B**.

---

## Formatting and Linting

Before committing changes, ensure the code follows the style guidelines:

```bash
npm run lint    # Check for errors
npm run fmt     # Auto-fix formatting (TS and Java)
```
