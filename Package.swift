// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LightstreamerClient",
    platforms: [
        .iOS(SupportedPlatform.IOSVersion.v13),
        .macOS(SupportedPlatform.MacOSVersion.v10_15),
        .watchOS(SupportedPlatform.WatchOSVersion.v6),
        .tvOS(SupportedPlatform.TVOSVersion.v13)
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "LightstreamerClient",
            targets: ["LightstreamerClient"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
        // NB keep in sync with LightstreamerClient.podspec
//        .package(url: "https://github.com/daltoniam/Starscream.git", .upToNextMajor(from: "4.0.6")),
//        .package(url: "https://github.com/Alamofire/Alamofire.git", .upToNextMajor(from: "5.8.1")),
//        .package(url: "https://github.com/raymccrae/swift-jsonpatch.git", .upToNextMajor(from: "1.0.5")),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "LightstreamerClient",
//            dependencies: ["Starscream", "Alamofire", .product(name: "JSONPatch", package: "swift-jsonpatch")]),
            dependencies: []),
        .testTarget(
            name: "LightstreamerClientTests",
            dependencies: ["LightstreamerClient"]),
    ]
)
