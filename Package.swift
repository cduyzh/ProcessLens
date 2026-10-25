// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "cduyzhProcessTool",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "cduyzhProcessTool", targets: ["ProcessApp"])],
    dependencies: [],
    targets: [
        .target(name: "ProcessCore", path: "Sources/ProcessCore"),
        .executableTarget(name: "ProcessApp", dependencies: ["ProcessCore"], path: "Sources/ProcessApp"),
        .testTarget(name: "ProcessCoreTests", dependencies: ["ProcessCore"], path: "Tests/ProcessCoreTests")
    ]
)
