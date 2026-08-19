// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DarwinRelayNative",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MacUIHelper", targets: ["MacUIHelper"]),
        .executable(name: "MacUICursorOverlay", targets: ["MacUICursorOverlay"]),
        .executable(name: "DarwinRelayMenu", targets: ["DarwinRelayMenu"]),
        .executable(name: "DarwinRelayDesktopFixture", targets: ["DarwinRelayDesktopFixture"]),
    ],
    targets: [
        .executableTarget(
            name: "MacUIHelper",
            path: "desktop-helper",
            exclude: ["MacUICursorOverlay.swift"],
            sources: ["MacUIHelper.swift", "DesktopAdvanced.swift"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("Vision"),
            ]
        ),
        .executableTarget(
            name: "MacUICursorOverlay",
            path: "desktop-helper",
            exclude: ["MacUIHelper.swift", "DesktopAdvanced.swift"],
            sources: ["MacUICursorOverlay.swift"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("CoreGraphics")]
        ),
        .executableTarget(
            name: "DarwinRelayMenu",
            path: "menubar",
            exclude: ["build.sh"],
            sources: ["MenuBarApp.swift", "TunnelURL.swift"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .executableTarget(
            name: "DarwinRelayDesktopFixture",
            path: "tests/fixtures",
            exclude: ["poisoned-repository.md", "poisoned-repository.mjs", "stub-mcp-server.mjs"],
            sources: ["DesktopControlFixture.swift"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
    ]
)
