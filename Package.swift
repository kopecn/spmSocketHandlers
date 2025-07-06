// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SocketHandlers",
    platforms: [
        .macOS(.v14), // Minimum macOS version
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "NIOHandler",
            targets: ["NIOHandler"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/daikimat/depermaid.git", from: "1.1.0"),
        .package(url: "https://github.com/OpenCombine/OpenCombine.git", from: "0.14.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "NIOHandler",
            dependencies: [
                "SocketCommon",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "OpenCombine", package: "OpenCombine"),
            ],
            path: "spm/Sources/NIOHandler",
        ),
        .target(
            name: "SocketCommon",
            path: "spm/Sources/SocketCommon"
        ),
        .testTarget(
            name: "SocketHandlersTests",
            dependencies: ["NIOHandler"],
            path: "spm/Tests/NIOHandlerTests"
        ),
    ]
)
