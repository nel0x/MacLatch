// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacLatch",
    platforms: [.macOS(.v13)],
    targets: [
        // Security-relevant logic. No AppKit, no IOKit, no real hardware:
        // everything here is unit-testable.
        .target(name: "MacLatchCore"),

        // Menu bar app: AppKit UI, IOKit device monitoring, screen lock backend.
        .executableTarget(
            name: "MacLatch",
            dependencies: ["MacLatchCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),

        .testTarget(
            name: "MacLatchCoreTests",
            dependencies: ["MacLatchCore"]
        ),
    ]
)
