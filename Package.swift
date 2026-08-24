// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LucentChess",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LucentChess", targets: ["LucentChess"])
    ],
    targets: [
        .executableTarget(
            name: "LucentChess",
            path: "Sources/LucentChess",
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "LucentChessTests",
            dependencies: ["LucentChess"]
        )
    ]
)
