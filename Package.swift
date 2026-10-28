// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "BlueSwitch",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "BlueSwitch", targets: ["BlueSwitch"])
  ],
  targets: [
    .executableTarget(
      name: "BlueSwitch",
      path: "Sources/BlueSwitch",
      linkerSettings: [
        .linkedFramework("ApplicationServices"),
        .linkedFramework("IOBluetooth"),
        .linkedFramework("IOKit"),
        .linkedFramework("Carbon"),
        .linkedFramework("ServiceManagement"),
      ]
    )
  ]
)
