// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipDesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClipDesk", targets: ["ClipDesk"]),
        .library(name: "ClipDeskUI", targets: ["ClipDeskUI"]),
        .library(name: "ClipDeskCore", targets: ["ClipDeskCore"]),
    ],
    targets: [
        // Clipboard engine, persistence, and services. No SwiftUI.
        .target(name: "ClipDeskCore"),
        // SwiftUI/AppKit presentation: scenes, windows, Menu Bar popover, settings.
        .target(name: "ClipDeskUI", dependencies: ["ClipDeskCore"]),
        // Thin executable entry point.
        .executableTarget(name: "ClipDesk", dependencies: ["ClipDeskUI"]),
        .testTarget(name: "ClipDeskCoreTests", dependencies: ["ClipDeskCore"]),
    ]
)
