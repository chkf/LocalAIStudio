// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "ModelValidation",
    platforms: [.macOS(.v13)],
    products: [],
    targets: [
        .target(name: "ModelValidation", path: "Sources"),
        .testTarget(name: "ModelValidationTests", dependencies: ["ModelValidation"], path: "Tests")
    ]
)
