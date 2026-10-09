// swift-tools-version: 6.0

import PackageDescription
import Foundation

let helperInfoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Sources/WonderFanHelper/Resources/Info.plist").path

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
        .target(name: "WonderSupport", path: "Sources/WonderSupport"),
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
            dependencies: ["CSMC", "WonderSupport"],
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
                .linkedFramework("Metal"),
                .linkedFramework("Security"),
                .linkedFramework("Charts")
            ]
        ),
        .executableTarget(
            name: "WonderFanHelper",
            dependencies: ["CSMC", "WonderSupport"],
            path: "Sources/WonderFanHelper",
            exclude: ["Resources/Info.plist"],
            linkerSettings: [
                .linkedFramework("Security"),
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", helperInfoPlist])
            ]
        ),
        .executableTarget(
            name: "WonderMaintenanceHelper",
            path: "Sources/WonderMaintenanceHelper"
        ),
        .testTarget(
            name: "WonderBoxTests",
            dependencies: ["WonderBox", "WonderSupport"],
            path: "Tests/WonderBoxTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
