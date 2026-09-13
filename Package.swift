// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "SwiftCBORLD",
  platforms: [
    .macOS(.v13),
    .iOS(.v16),
    .tvOS(.v16),
    .watchOS(.v9),
    .visionOS(.v1),
  ],
  products: [
    .library(name: "CBORLD", targets: ["CBORLD"])
  ],
  targets: [
    .target(name: "CBORLD"),
    .testTarget(
      name: "CBORLDTests",
      dependencies: ["CBORLD"],
      resources: [.copy("Fixtures")]),
  ]
)
