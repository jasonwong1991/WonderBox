// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WonderBox",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "WonderBox", targets: ["WonderBox"]),
        .executable(name: "WonderFanHelper", targets: ["WonderFanHelper"]),
        .executable(name: "WonderMaintenanceHelper", targets: ["WonderMaintenanceHelper"])
    ],
    targets: [
        .target(
            name: "CSMC",
            path: "Sources/CSMC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "WonderBox",
            dependencies: ["CSMC"],
            path: "Sources/WonderBox",
            exclude: [
                "Resources/Info.plist",
                "Resources/PrivacyInfo.xcprivacy",
                "Resources/com.wondercraft.WonderBox.FanHelper.plist",
                "Resources/WonderBox-AppStore.entitlements"
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreServices"),
                .linkedFramework("IOKit"),
                .linkedFramework("Charts")
            ]
        ),
        .executableTarget(
            name: "WonderFanHelper",
            dependencies: ["CSMC"],
            path: "Sources/WonderFanHelper"
        ),
        .executableTarget(
            name: "WonderMaintenanceHelper",
            path: "Sources/WonderMaintenanceHelper"
        ),
        .testTarget(
            name: "WonderBoxTests",
            dependencies: ["WonderBox"],
            path: "Tests/WonderBoxTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
