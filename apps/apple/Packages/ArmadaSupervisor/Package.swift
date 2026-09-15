// swift-tools-version: 6.2
import PackageDescription

// The voice supervisor's decisions, kept apart from the microphone, the panel and the process
// that act on them: what a line of `claude`'s stream-json output means, which words are ready
// to speak, when a pause ends a question, and what a shortcut press does in each state.
//
// None of it needs audio, a window or a spawned binary, which is what lets `swift test` pin
// it against the frames measured on 2026-09-15 (docs/claude-code-sessions.md, "Driving a
// headless session over stream-json"). The app target holds everything that does.
let package = Package(
  name: "ArmadaSupervisor",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "ArmadaSupervisor", targets: ["ArmadaSupervisor"])
  ],
  targets: [
    .target(name: "ArmadaSupervisor"),
    .testTarget(name: "ArmadaSupervisorTests", dependencies: ["ArmadaSupervisor"]),
  ]
)
