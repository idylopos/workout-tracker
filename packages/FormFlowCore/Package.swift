// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FormFlowCore",
    platforms: [.macOS(.v14), .iOS("26.0"), .watchOS("26.0")],
    products: [.library(name: "FormFlowCore", targets: ["FormFlowCore"])],
    targets: [
        .target(name: "FormFlowCore", resources: [.process("Resources")]),
        .testTarget(name: "FormFlowCoreTests", dependencies: ["FormFlowCore"])
    ]
)
