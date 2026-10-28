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
    .executable(name: "cborld", targets: ["CBORLDTool"]),
  ],
  targets: [
    .target(name: "CBORLD"),
    .target(name: "CBORLDCompute", dependencies: ["CBORLD"]),
    // The `cborld` command. Its commands live in a library target so tests
    // can run them in-process.
    .target(name: "CBORLDCommandLine", dependencies: ["CBORLD"]),
    .executableTarget(name: "CBORLDTool", dependencies: ["CBORLDCommandLine"]),
    .testTarget(
      name: "CBORLDTests",
      dependencies: ["CBORLD", "CBORLDCompute"],
      resources: [.copy("Fixtures")]),
    .testTarget(
      name: "CBORLDComputeTests",
      dependencies: ["CBORLD", "CBORLDCompute"]),
    .testTarget(
      name: "CBORLDCommandLineTests",
      dependencies: ["CBORLD", "CBORLDCommandLine"]),
  ]
)
