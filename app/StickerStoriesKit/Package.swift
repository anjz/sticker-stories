// swift-tools-version: 6.4
import PackageDescription

// StickerStoriesKit holds the platform-independent core of the app: pack
// manifest models, canvas state, story selection, and entitlement logic.
// It also builds for macOS so `swift test` runs on the Mac host without a
// simulator. This is first-party code, not a third-party dependency.
let package = Package(
    name: "StickerStoriesKit",
    platforms: [.iOS(.v27), .macOS(.v27)],
    products: [
        .library(name: "StickerStoriesKit", targets: ["StickerStoriesKit"])
    ],
    targets: [
        .target(name: "StickerStoriesKit"),
        .testTarget(name: "StickerStoriesKitTests", dependencies: ["StickerStoriesKit"]),
    ]
)
