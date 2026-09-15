// swift-tools-version: 6.2
import PackageDescription

// The seam between Armada and `swift-mcp-kit`, in Almanac's shape: the protocol and the
// listener live in the kit and know nothing about this app, and everything that names a
// session, an account or a plan window lives here.
//
// What is deliberately NOT here: `Accounts`, `CodexAccounts` and the watchers behind them.
// They belong to the app target, so this package addresses them through the `FleetSource`
// protocol instead. That is what lets the tool table and every response shape be tested
// offline against a fake, with no app, no config folder and no bound port.
//
// A remote dependency rather than Almanac's absolute `path:`, because CI builds this and has
// no checkout of the kit beside the repo. Same identity as the app's own reference, so Xcode
// resolves one copy.
let package = Package(
  name: "ArmadaMCP",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "ArmadaMCP", targets: ["ArmadaMCP"])
  ],
  dependencies: [
    .package(url: "https://github.com/mgcrea/swift-mcp-kit.git", from: "1.0.0")
  ],
  targets: [
    .target(
      name: "ArmadaMCP",
      dependencies: [
        .product(name: "MCPKit", package: "swift-mcp-kit"),
        .product(name: "MCPKitLoopback", package: "swift-mcp-kit"),
      ]),
    .testTarget(name: "ArmadaMCPTests", dependencies: ["ArmadaMCP"]),
  ]
)
