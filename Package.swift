// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "messages-reader",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "messages-reader-service", targets: ["messages-reader-service"]),
        .executable(name: "messages-read", targets: ["messages-read"]),
    ],
    targets: [
        // Paths and the JSON value type: everything the client and service share.
        .target(name: "ReaderShared"),
        // Database access and the socket server. Only the service links this.
        .target(name: "ReaderCore", dependencies: ["ReaderShared"]),
        .executableTarget(name: "messages-reader-service", dependencies: ["ReaderCore"]),
        .executableTarget(name: "messages-read", dependencies: ["ReaderShared"]),
        .testTarget(name: "ReaderCoreTests", dependencies: ["ReaderCore", "ReaderShared"]),
    ],
    swiftLanguageModes: [.v5]
)
