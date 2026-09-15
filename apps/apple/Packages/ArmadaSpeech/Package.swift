// swift-tools-version: 6.2
import PackageDescription

// Parakeet speech recognition for voice, and the one place FluidAudio is linked.
//
// **A dynamic library on purpose.** FluidAudio carries a model downloader built on URLSession.
// Linked statically, those symbols would land in Armada's own executable, and `make audit`
// could only pardon the whole app. As a framework of its own they sit in one Mach-O,
// `Contents/Frameworks/ArmadaSpeech.framework`, and the audit's allowance names that binary and
// the exact symbols it was measured to use, the way it names Sparkle's.
//
// FluidAudio is pinned to a revision rather than a version, as Cadence pins it: the tagged
// release's documentation does not compile against its own sources, and this is the revision
// Parakeet was measured with on 2026-09-15.
let package = Package(
  name: "ArmadaSpeech",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "ArmadaSpeech", type: .dynamic, targets: ["ArmadaSpeech"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/FluidInference/FluidAudio.git",
      revision: "6428e29186573c6d33c598e25d460e6690bc0ee1")
  ],
  targets: [
    .target(
      name: "ArmadaSpeech",
      dependencies: [.product(name: "FluidAudio", package: "FluidAudio")])
  ]
)
