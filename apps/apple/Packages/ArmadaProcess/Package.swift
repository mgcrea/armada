// swift-tools-version: 6.2
import PackageDescription

// The short-lived commands Armada runs and reads an answer from: `claude` and `grok` control
// requests, `codex queue`, VS Code's `code`, and the person's login shell. Each one is bounded
// by a deadline, stops with its task, and takes its process group down with it.
//
// Built on swift-subprocess, the Swift project's own process library, rather than Foundation's
// `Process`: a run is scoped to one `await`, cancelling the task tears the child down, and a read
// ends when the child exits even if a grandchild still holds the pipe. Those three were each a
// watchdog, a drain thread or a temp file per caller before. Kept out of the app target so
// `swift test` can run the measured shell cases (a hung interactive zsh, a job left in the
// background) without the app. The two children Armada keeps running and talks to between calls,
// the voice supervisor and a headless Grok turn, stay on `Process` in the app.
let package = Package(
  name: "ArmadaProcess",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "ArmadaProcess", targets: ["ArmadaProcess"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/swiftlang/swift-subprocess.git", .upToNextMinor(from: "1.0.2"))
  ],
  targets: [
    .target(
      name: "ArmadaProcess",
      dependencies: [.product(name: "Subprocess", package: "swift-subprocess")]),
    .testTarget(name: "ArmadaProcessTests", dependencies: ["ArmadaProcess"]),
  ]
)
