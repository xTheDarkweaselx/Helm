// swift-tools-version: 6.0
import PackageDescription

// SPIKE 2 (DEVELOPMENT_PLAN.md §7): does CoreXLSX resolve + build under
// Xcode 26 / Swift 6 across iOS / macOS / visionOS, and how does it handle dates?
// Throwaway: not wired into the app. Run `swift run CoreXLSXSpike <file.xlsx>`.
let package = Package(
    name: "CoreXLSXSpike",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v1),
    ],
    dependencies: [
        .package(url: "https://github.com/CoreOffice/CoreXLSX.git", from: "0.14.2"),
    ],
    targets: [
        .executableTarget(
            name: "CoreXLSXSpike",
            dependencies: ["CoreXLSX"]
        ),
    ]
)
