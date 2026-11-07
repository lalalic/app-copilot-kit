// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppCopilotKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "AppCopilotKit", targets: ["AppCopilotKit"])],
    targets: [
        .target(name: "AppCopilotKit"),
        .testTarget(name: "AppCopilotKitTests", dependencies: ["AppCopilotKit"])
    ]
)
