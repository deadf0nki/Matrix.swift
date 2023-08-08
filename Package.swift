// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Matrix.swift",
    platforms: [
        .iOS(.v16),
        .tvOS(.v16),
        .macCatalyst(.v16),
        .macOS(.v13)
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "Matrix",
            targets: ["Matrix"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.13.3"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "5.24.0"),
        .package(url: "https://github.com/Flight-School/AnyCodable", from: "0.6.0"),
        .package(url: "https://gitlab.futo.org/cvwright/BlindSaltSpeke.git", from: "0.4.2"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://gitlab.futo.org/circles/MatrixSDKCrypto.git", exact: "0.2.1"), //from: "0.1.5"),
        .package(url: "https://github.com/iosdevzone/IDZSwiftCommonCrypto.git", from: "0.13.0"),
        .package(url: "https://github.com/apple/swift-collections.git", branch: "release/1.1"),
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.2.2"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "Matrix",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "AnyCodable", package: "anycodable"),
                .product(name: "BlindSaltSpeke", package: "blindsaltspeke"),
                .product(name: "MatrixSDKCrypto", package: "MatrixSDKCrypto"),
                .product(name: "IDZSwiftCommonCrypto", package: "IDZSwiftCommonCrypto"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "KeychainAccess", package: "KeychainAccess"),
            ]),
        .testTarget(
            name: "MatrixTests",
            dependencies: [
                "Matrix",
                .product(name: "SQLite", package: "SQLite.swift"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "AnyCodable", package: "anycodable"),
                .product(name: "BlindSaltSpeke", package: "blindsaltspeke"),
                .product(name: "Yams", package: "yams"),
            ],
            resources: [
                .copy("TestConfig.yaml")
            ]),
    ]
)
