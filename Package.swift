// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MeetingScribe",
    platforms: [
        .macOS(.v13)  // ScreenCaptureKit requires macOS 13+
    ],
    products: [
        .executable(
            name: "meetingscribe",
            targets: ["MeetingScribe"]
        )
    ],
    dependencies: [
        // No external dependencies - using native frameworks
    ],
    targets: [
        .executableTarget(
            name: "MeetingScribe",
            path: "src"
        ),
        .testTarget(
            name: "MeetingScribeTests",
            dependencies: ["MeetingScribe"],
            path: "tests"
        )
    ]
)
