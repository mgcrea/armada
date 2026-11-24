import BuildSlotCore
import Testing

// Which invocations take a slot. A row that queues wrongly holds a slot for something that
// does not build (or for days, as WebDriverAgent would); one that passes through wrongly lets
// a build run unqueued, so both directions are pinned.
struct InvocationTests {
  private func queues(_ tool: Tool, _ line: String) -> Bool {
    Invocation.queues(tool, arguments: line.split(separator: " ").map(String.init))
  }

  // MARK: swift

  @Test func swiftBuildQueues() { #expect(queues(.swift, "build") == true) }

  @Test func swiftTestWithPackagePathQueues() {
    #expect(queues(.swift, "test --package-path Packages/X") == true)
  }

  // Measured 2026-11-24: `swift --package-path /x build` fails with "unknown argument:
  // '--package-path'", and `swift -c release build` with "option '-c' is not supported by
  // 'swift'". The driver dispatches a subcommand only as the first argument, so this builds
  // nothing.
  @Test func swiftOptionBeforeSubcommandPassesThrough() {
    #expect(queues(.swift, "--package-path P test --filter Foo") == false)
  }

  @Test func swiftShowBinPathPassesThrough() {
    #expect(queues(.swift, "build --show-bin-path") == false)
  }

  @Test(arguments: ["test --help", "build -h", "build --version"])
  func swiftHelpAndVersionPassThrough(line: String) {
    #expect(queues(.swift, line) == false)
  }

  @Test(arguments: ["run", "run MyTool --flag", "package resolve", "format", "repl", "--version"])
  func swiftOtherSubcommandsPassThrough(line: String) {
    #expect(queues(.swift, line) == false)
  }

  @Test func swiftWithNoArgumentsPassesThrough() {
    #expect(Invocation.queues(.swift, arguments: []) == false)
  }

  // MARK: xcodebuild

  @Test func xcodebuildBuildQueues() {
    #expect(queues(.xcodebuild, "build -project A.xcodeproj -scheme A") == true)
  }

  @Test func xcodebuildWithNoActionQueues() {
    #expect(
      queues(.xcodebuild, "-project A.xcodeproj -scheme A -destination platform=macOS") == true)
  }

  @Test func xcodebuildTestQueues() {
    #expect(queues(.xcodebuild, "test -scheme A -destination platform=macOS") == true)
  }

  @Test func xcodebuildSchemeNamedBuildIsNotAnAction() {
    #expect(queues(.xcodebuild, "-scheme build test") == true)
  }

  @Test func xcodebuildSchemeNamedTestDefaultsToBuild() {
    #expect(queues(.xcodebuild, "-scheme test") == true)
  }

  @Test(arguments: ["archive", "analyze", "install", "docbuild", "build-for-testing"])
  func xcodebuildBuildingActionsQueue(line: String) {
    #expect(queues(.xcodebuild, line) == true)
  }

  @Test func xcodebuildTestWithoutBuildingPassesThrough() {
    #expect(queues(.xcodebuild, "test-without-building -xctestrun x.xctestrun") == false)
  }

  @Test(arguments: ["clean", "installsrc"])
  func xcodebuildNonBuildingActionsPassThrough(line: String) {
    #expect(queues(.xcodebuild, line) == false)
  }

  @Test(arguments: [
    "-showBuildSettings -scheme A", "-list", "-version", "-exportArchive -archivePath a",
    "-resolvePackageDependencies", "-showsdks", "-showdestinations -scheme A", "-showTestPlans",
    "-create-xcframework", "-checkFirstLaunchStatus", "-runFirstLaunch", "-help", "-usage",
  ])
  func xcodebuildQueryFlagsPassThrough(line: String) {
    #expect(queues(.xcodebuild, line) == false)
  }

  @Test func xcodebuildWebDriverAgentPassesThrough() {
    #expect(
      queues(.xcodebuild, "test -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner")
        == false)
  }

  @Test func xcodebuildBuildSettingIsNotAnAction() {
    #expect(queues(.xcodebuild, "build CODE_SIGNING_ALLOWED=NO -scheme A") == true)
  }

  // MARK: The fleet's Makefiles

  /// Every `swift` and `xcodebuild` line of maquette's and this repo's `apps/apple/Makefile`,
  /// with the Make variables expanded to their values, as the shim would receive them.
  @Test func fleetMakefileInvocations() {
    let rows: [(Tool, [String], Bool)] = [
      // armada `build`
      (
        .xcodebuild,
        [
          "build", "-project", "Armada.xcodeproj", "-scheme", "Armada", "-configuration", "Debug",
          "-destination", "platform=macOS", "-derivedDataPath", ".build",
        ], true
      ),
      // armada `test`
      (.swift, ["test", "--package-path", "Packages/ArmadaMCP"], true),
      (.swift, ["test", "--package-path", "Packages/ArmadaSupervisor"], true),
      (.swift, ["test", "--package-path", "Packages/BuildSlot"], true),
      // maquette `build`, `build-release`, `build-ios`
      (
        .xcodebuild,
        [
          "build", "-project", "Maquette.xcodeproj", "-scheme", "Maquette", "-configuration",
          "Debug", "-destination", "platform=macOS", "-derivedDataPath", ".build",
        ], true
      ),
      (
        .xcodebuild,
        [
          "build", "-project", "Maquette.xcodeproj", "-scheme", "Maquette", "-configuration",
          "Release", "-destination", "platform=macOS", "-derivedDataPath", ".build",
        ], true
      ),
      (
        .xcodebuild,
        [
          "build", "-quiet", "-project", "Maquette.xcodeproj", "-scheme", "Maquette",
          "-configuration", "Debug", "-destination", "generic/platform=iOS Simulator",
          "-derivedDataPath", ".build",
        ], true
      ),
      // maquette `test`, `test-render`, `test-mcp`, `fixtures`
      (.swift, ["test", "--package-path", "Packages/MaquetteKit"], true),
      (.swift, ["test", "--package-path", "Packages/MaquetteRender"], true),
      (.swift, ["test", "--package-path", "Packages/MaquetteMCP"], true),
      (
        .swift,
        ["test", "--package-path", "Packages/MaquetteKit", "--filter", "CheckFixtureTests"], true
      ),
      // maquette `test-app`
      (
        .xcodebuild,
        [
          "test", "-project", "Maquette.xcodeproj", "-scheme", "Maquette", "-destination",
          "platform=macOS", "-derivedDataPath", ".build",
        ], true
      ),
      // maquette `archive-mac`, `archive-ios`: the action comes last
      (
        .xcodebuild,
        [
          "-project", "Maquette.xcodeproj", "-scheme", "Maquette", "-configuration", "Release",
          "-destination", "generic/platform=macOS", "-archivePath",
          ".build/Maquette-macos.xcarchive", "-allowProvisioningUpdates", "archive",
        ], true
      ),
      (
        .xcodebuild,
        [
          "-project", "Maquette.xcodeproj", "-scheme", "Maquette", "-configuration", "Release",
          "-destination", "generic/platform=iOS", "-archivePath",
          ".build/Maquette-ios.xcarchive", "-allowProvisioningUpdates", "archive",
        ], true
      ),
      // maquette `export-mac`, `export-ios`
      (
        .xcodebuild,
        [
          "-exportArchive", "-archivePath", ".build/Maquette-macos.xcarchive",
          "-exportOptionsPlist", "ExportOptions.plist", "-exportPath", ".build/export-macos",
          "-allowProvisioningUpdates",
        ], false
      ),
      (
        .xcodebuild,
        [
          "-exportArchive", "-archivePath", ".build/Maquette-ios.xcarchive",
          "-exportOptionsPlist", "ExportOptions.plist", "-exportPath", ".build/export-ios",
          "-allowProvisioningUpdates",
        ], false
      ),
      // maquette's bundle lookup (comment at its `run` target)
      (
        .xcodebuild,
        [
          "-showBuildSettings", "-project", "Maquette.xcodeproj", "-scheme", "Maquette",
          "-configuration", "Debug",
        ], false
      ),
    ]
    for (tool, arguments, expected) in rows {
      #expect(
        Invocation.queues(tool, arguments: arguments) == expected,
        "\(tool.rawValue) \(arguments.joined(separator: " "))")
    }
  }
}
