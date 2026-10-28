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
    .library(name: "CBORLD", targets: ["CBORLD"]),
    .library(name: "CBORLDCompute", targets: ["CBORLDCompute"]),
  ],
  targets: [
    .target(name: "CBORLD"),
    .target(name: "CBORLDCompute", dependencies: ["CBORLD"]),
    .testTarget(
      name: "CBORLDTests",
      dependencies: ["CBORLD", "CBORLDCompute"],
      resources: [.copy("Fixtures")]),
    .testTarget(
      name: "CBORLDComputeTests",
      dependencies: ["CBORLD", "CBORLDCompute"]),
  ]
)
