// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "cses_collab_core",
    platforms: [.iOS("14.0")],
    products: [
        .library(name: "cses-collab-core", targets: ["cses_collab_core"])
    ],
    targets: [
        .binaryTarget(name: "cses_collab_core", path: "cses_collab_core.xcframework")
    ]
)
