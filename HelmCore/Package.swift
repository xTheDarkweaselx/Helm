// swift-tools-version: 6.0
import PackageDescription

// HelmCore — platform-neutral, headlessly-testable core for Helm (ADR-8).
// Pure value types and logic; no UI, no EventKit/SwiftData. Wired into the app
// target via "Add Local Package" in Xcode. Deployment minima are kept low (the
// code is pure Foundation) so `swift test` runs on the host and the app (min 26.5)
// can still depend on it.
//
// The `CoreXLSX` target is a VENDORED FORK of CoreOffice/CoreXLSX (Apache-2.0):
// lenient relationship/cell-type enums + a date1904 accessor (ADR-7, Spike 2).
// See Sources/CoreXLSX/LICENSE.md and THIRD-PARTY-NOTICES.md.
let package = Package(
    name: "HelmCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "HelmDomain", targets: ["HelmDomain"]),
        .library(name: "HelmParsing", targets: ["HelmParsing"]),
        .library(name: "HelmCalendar", targets: ["HelmCalendar"]),
    ],
    dependencies: [
        .package(url: "https://github.com/CoreOffice/XMLCoder.git", exact: "0.14.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: [
        // Vendored fork of CoreXLSX (Apache-2.0). Kept in Swift 5 language mode:
        // upstream is tools-5.1 and not strict-concurrency clean; our code never
        // crosses an actor boundary with its non-Sendable types.
        .target(
            name: "CoreXLSX",
            dependencies: [
                .product(name: "XMLCoder", package: "XMLCoder"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            exclude: ["LICENSE.md"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(name: "HelmDomain"),
        .target(name: "HelmParsing", dependencies: ["HelmDomain", "CoreXLSX"]),
        .target(name: "HelmCalendar", dependencies: ["HelmDomain"]),
        .testTarget(name: "HelmDomainTests", dependencies: ["HelmDomain"]),
        .testTarget(
            name: "HelmParsingTests",
            dependencies: ["HelmParsing"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
