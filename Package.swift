// swift-tools-version:5.4
import PackageDescription

let package = Package(
    name: "VolumeGuard",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        .library(name: "VolumeGuardCore", targets: ["VolumeGuardCore"]),
        .executable(name: "VolumeGuard", targets: ["VolumeGuard"]),
        .executable(name: "VolumeGuardCoreChecks", targets: ["VolumeGuardCoreChecks"])
    ],
    targets: [
        .target(
            name: "VolumeGuardCore",
            dependencies: []
        ),
        .executableTarget(
            name: "VolumeGuard",
            dependencies: ["VolumeGuardCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .executableTarget(
            name: "VolumeGuardCoreChecks",
            dependencies: ["VolumeGuardCore"],
            path: "Tests/VolumeGuardCoreChecks"
        )
    ]
)
