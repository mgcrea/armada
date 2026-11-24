// swift-tools-version: 6.2
import PackageDescription

// Build slots: a machine-wide queue for `swift build|test` and `xcodebuild`, taken by PATH
// shims that hold an fcntl lock on a slot file while the real tool runs
// (docs/superpowers/specs/2026-11-24-build-slots-design.md).
//
// A package rather than app code because the `buildslot` tool must run without Armada: a shim
// queues builds whether or not the app is open. The app links `BuildSlotCore` to show the
// queue, so the reader and the writer share one slot-file format instead of two copies of it.
let package = Package(
  name: "BuildSlot",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "BuildSlotCore", targets: ["BuildSlotCore"]),
    .executable(name: "buildslot", targets: ["buildslot"]),
  ],
  targets: [
    .target(name: "BuildSlotCore"),
    .executableTarget(name: "buildslot", dependencies: ["BuildSlotCore"]),
    // Depends on `buildslot` too, so `swift test` builds the binary the process tests run.
    .testTarget(name: "BuildSlotCoreTests", dependencies: ["BuildSlotCore", "buildslot"]),
  ]
)
