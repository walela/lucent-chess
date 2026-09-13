// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LucentChess",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LucentChess", targets: ["LucentChess"]),
        .executable(name: "LucentChessCBH", targets: ["LucentChessCBH"])
    ],
    targets: [
        .executableTarget(
            name: "LucentChess",
            path: "Sources/LucentChess",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "LucentChessCBH",
            path: "Tools/ChessBaseReader",
            exclude: ["README.md", "libcbh/README.md", "libcbh/LICENSE"],
            sources: ["main.cpp", "libcbh/src"],
            cxxSettings: [.headerSearchPath("libcbh/include"), .headerSearchPath("libcbh/src")]
        ),
        .testTarget(
            name: "LucentChessTests",
            dependencies: ["LucentChess"]
        )
    ],
    cxxLanguageStandard: .cxx20
)
