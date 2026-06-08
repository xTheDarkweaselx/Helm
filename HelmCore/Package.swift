// swift-tools-version: 6.0
import PackageDescription

// HelmCore — platform-neutral, headlessly-testable core for Helm (ADR-8).
// Pure value types and logic; no UI, no EventKit/SwiftData. Wired into the app
// target via "Add Local Package" in Xcode. Deployment minima are kept low (the
// code is pure Foundation) so `swift test` runs on the host and the app (min 26.5)
// can still depend on it.
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
    targets: [
        .target(name: "HelmDomain"),
        .target(name: "HelmParsing", dependencies: ["HelmDomain"]),
        .target(name: "HelmCalendar", dependencies: ["HelmDomain"]),
        .testTarget(name: "HelmDomainTests", dependencies: ["HelmDomain"]),
        .testTarget(name: "HelmParsingTests", dependencies: ["HelmParsing"]),
    ]
)
