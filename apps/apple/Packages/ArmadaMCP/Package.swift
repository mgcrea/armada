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
// A remote dependency rather than an absolute `path:`, because CI builds this and has no
// checkout of the kit beside the repo. Up to the next minor, like `swift-support-kit` here and
// in Bastion and Cupertino: a kit release is picked up on purpose, by bumping this line.
// To work on the kit and the app together, drop the kit's folder into the workspace as a local
// override rather than editing this line.
let package = Package(
  name: "ArmadaMCP",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "ArmadaMCP", targets: ["ArmadaMCP"])
  ],
  dependencies: [
    .package(url: "https://github.com/mgcrea/swift-mcp-kit.git", .upToNextMinor(from: "1.1.0"))
  ],
  targets: [
    .target(
      name: "ArmadaMCP",
      dependencies: [
        .product(name: "MCPKit", package: "swift-mcp-kit"),
        .product(name: "MCPKitLoopback", package: "swift-mcp-kit"),
        // Not used by this package's own code: it is here so the app target, which links
        // only `ArmadaMCP`, can import it. See `MCPClientWiring`.
        .product(name: "MCPKitWiring", package: "swift-mcp-kit"),
      ]),
    .testTarget(name: "ArmadaMCPTests", dependencies: ["ArmadaMCP"]),
  ]
)
