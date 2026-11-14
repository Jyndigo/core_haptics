// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "core_haptics",
  platforms: [
    .iOS("13.0"),
    .macOS("11.0"),
  ],
  products: [
    .library(name: "core-haptics", targets: ["core_haptics"])
  ],
  dependencies: [],
  targets: [
    .target(
      name: "core_haptics",
      dependencies: [],
      path: "Sources/core_haptics",
      publicHeadersPath: "include"
    )
  ]
)
