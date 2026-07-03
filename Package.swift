// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "teams-to-obsidian",
    platforms: [
        // Core Audio process taps + the "System Audio Recording Only" TCC
        // category require macOS 14.4.
        .macOS("14.4")
    ],
    products: [
        .executable(name: "teams-to-obsidian", targets: ["teams-to-obsidian"])
    ],
    dependencies: [
        // Pinned exact: BedrockSummarizer uses APIs verified at this version
        // (incl. the deprecated-but-working BedrockRuntimeClientConfiguration).
        .package(url: "https://github.com/awslabs/aws-sdk-swift", exact: "1.7.30"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "teams-to-obsidian",
            dependencies: ["TeamsToObsidianKit"]
        ),
        .target(
            name: "TeamsToObsidianKit",
            dependencies: [
                .product(name: "AWSBedrockRuntime", package: "aws-sdk-swift"),
                .product(name: "AWSSDKIdentity", package: "aws-sdk-swift"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "TeamsToObsidianKitTests",
            dependencies: ["TeamsToObsidianKit"]
        ),
    ]
)
