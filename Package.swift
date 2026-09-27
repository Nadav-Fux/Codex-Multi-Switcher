// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexMultiSwitcher",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CodexProfileCore",
            targets: ["CodexProfileCore"]),
        .executable(
            name: "CodexMultiSwitcher",
            targets: ["CodexMultiSwitcherApp"]),
        .executable(
            name: "codex-profile",
            targets: ["CodexProfileCLI"]),
    ],
    targets: [
        .target(
            name: "CodexProfileCore",
            path: "Sources/CodexProfileCore"),
        .executableTarget(
            name: "CodexMultiSwitcherApp",
            dependencies: ["CodexProfileCore"],
            path: "Sources/CodexMultiSwitcherApp",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
            ]),
        .executableTarget(
            name: "CodexProfileCLI",
            dependencies: ["CodexProfileCore"],
            path: "Sources/CodexProfileCLI",
            linkerSettings: [
                .linkedFramework("Security"),
            ]),
        .testTarget(
            name: "AuthBlobTests",
            dependencies: ["CodexProfileCore"],
            path: "Tests/AuthBlobTests"),
        .testTarget(
            name: "ProfileSelectorTests",
            dependencies: ["CodexProfileCore"],
            path: "Tests/ProfileSelectorTests"),
        .testTarget(
            name: "LogRedactorTests",
            dependencies: ["CodexMultiSwitcherApp", "CodexProfileCore"],
            path: "Tests/LogRedactorTests",
            swiftSettings: [
                .define("TESTING"),
            ]),
        .testTarget(
            name: "ProfileStoreEnvironmentTests",
            dependencies: ["CodexMultiSwitcherApp", "CodexProfileCore"],
            path: "Tests/ProfileStoreEnvironmentTests",
            swiftSettings: [
                .define("TESTING"),
            ]),
        .testTarget(
            name: "TokenRenewalTests",
            dependencies: ["CodexProfileCore"],
            path: "Tests/TokenRenewalTests"),
    ]
)
