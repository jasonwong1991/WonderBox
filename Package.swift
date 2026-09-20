// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WonderBox",
    defaultLocalization: "en",
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
            // String catalogs are compiled into the app bundle by scripts/package_app.sh;
            // `swift build` would only copy the raw .xcstrings, which Foundation cannot load.
            exclude: [
                "Resources/Info.plist",
                "Resources/InfoPlist.xcstrings",
                "Resources/Localizable.xcstrings",
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
