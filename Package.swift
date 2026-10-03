// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenBar",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "TokenBar",
            targets: ["TokenBar"]
        ),
        .executable(
            name: "TokenBarProbe",
            targets: ["TokenBarProbe"]
        ),
        .executable(
            name: "tbar",
            targets: ["TokenBarCLI"]
        ),
        .library(
            name: "TokenBarCore",
            targets: ["TokenBarCore"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            from: "7.0.0"
        ),
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "937120cbc281cf29727fdfb8734482158508b4fc"
        ),
    ],
    targets: [
        .executableTarget(
            name: "TokenBar",
            dependencies: ["TokenBarCore"],
            path: "Sources/TokenBar",
            // CL-P2-010..013: Localizable.strings + RTL test fixture bundled
            // with the app. Resources live in Sources/TokenBar/L10n.
            // Resources/ adds the Prompt Templates editor's bundled examples.
            resources: [.process("L10n"), .process("Resources")]
        ),
        .executableTarget(
            name: "TokenBarProbe",
            dependencies: ["TokenBarCore"],
            path: "Sources/TokenBarProbe"
        ),
        .executableTarget(
            name: "TokenBarCLI",
            dependencies: ["TokenBarCore"],
            path: "Sources/TokenBarCLI"
        ),
        .testTarget(
            name: "TokenBarCLITests",
            dependencies: [
                "TokenBarCLI",
                "TokenBarCore",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/TokenBarCLITests"
        ),
        .target(
            name: "TokenBarCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/TokenBarCore"
        ),
        .testTarget(
            name: "TokenBarCoreTests",
            dependencies: [
                "TokenBarCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/TokenBarCoreTests",
            resources: [
                .process("Fixtures"),
            ]
        ),
    ]
)
