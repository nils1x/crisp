// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Crisp",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Crisp", targets: ["Crisp"])],
    targets: [
        .executableTarget(name: "Crisp"),
        .testTarget(name: "CrispTests", dependencies: ["Crisp"])
    ]
)
