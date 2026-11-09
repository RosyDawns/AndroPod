// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AndroPod",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AndroPod", targets: ["AndroPodApp"])
    ],
    targets: [
        .target(name: "AndroPodCore", path: "Sources/AndroPodCore"),
        .executableTarget(
            name: "AndroPodApp",
            dependencies: ["AndroPodCore"],
            path: "Sources/AndroPodApp"
        ),
    ]
)
