// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MessengerNotifications",
    platforms: [.iOS(.v13)],
    products: [
        .library(
            name: "MessengerNotifications",
            targets: ["MessengerNotificationsPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "7.1.0"),
        .package(url: "https://github.com/socketio/socket.io-client-swift.git", from: "16.1.0")
    ],
    targets: [
        .target(
            name: "MessengerNotificationsPlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                .product(name: "SocketIO", package: "socket.io-client-swift")
            ],
            path: "ios/Sources/MessengerNotificationsPlugin")
    ]
)
