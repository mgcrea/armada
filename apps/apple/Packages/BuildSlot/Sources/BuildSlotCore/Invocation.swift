/// A tool the shims stand in for.
public enum Tool: String, Sendable, CaseIterable {
  case swift, xcodebuild
}

/// Which invocations take a build slot: the ones that compile. Queries, `swift run` and test
/// runs that build nothing pass straight through, so they never wait behind a build, and a
/// long-lived process (a served `swift run`, a WebDriverAgent run kept up for days) never sits
/// on a slot.
public enum Invocation {
  /// Whether `tool` run with `arguments` (argv without argv[0]) waits for a slot.
  public static func queues(_ tool: Tool, arguments: [String]) -> Bool {
    switch tool {
    case .swift: swiftQueues(arguments)
    case .xcodebuild: xcodebuildQueues(arguments)
    }
  }

  // MARK: swift

  /// Flags after which `swift build|test` only prints, anywhere on the line.
  private static let swiftQueryFlags: Set<String> = [
    "--help", "-h", "--version", "--show-bin-path",
  ]

  /// The swift driver dispatches a subcommand only when it is the first argument:
  /// `swift --package-path P build` and `swift -c release build` are errors, not builds.
  private static func swiftQueues(_ arguments: [String]) -> Bool {
    if arguments.contains(where: swiftQueryFlags.contains) { return false }
    return arguments.first == "build" || arguments.first == "test"
  }

  // MARK: xcodebuild

  private static let xcodebuildBuildingActions: Set<String> = [
    "build", "build-for-testing", "test", "archive", "analyze", "install", "docbuild",
  ]

  /// Actions that build nothing. `test-without-building` runs tests already built, and with
  /// `-xctestrun` can run for as long as its tests do.
  private static let xcodebuildIdleActions: Set<String> = [
    "test-without-building", "clean", "installsrc",
  ]

  /// Flags that make xcodebuild answer a query or do something other than build.
  private static let xcodebuildQueryFlags: Set<String> = [
    "-showBuildSettings", "-list", "-version", "-exportArchive", "-resolvePackageDependencies",
    "-showsdks", "-showdestinations", "-showTestPlans", "-create-xcframework",
    "-checkFirstLaunchStatus", "-runFirstLaunch", "-help", "-usage",
    // Platform downloads run to gigabytes and compile nothing; localization export and import
    // only read strings out of a build, which no queue needs to hold back.
    "-downloadPlatform", "-downloadAllPlatforms", "-importPlatform", "-exportLocalizations",
    "-importLocalizations",
  ]

  /// Options whose next argument is their value, so `-scheme build test` is the action `test`
  /// on a scheme named `build`. Any other `-flag` takes no value.
  private static let xcodebuildValueOptions: Set<String> = [
    "-project", "-workspace", "-scheme", "-target", "-configuration", "-destination", "-sdk",
    "-arch", "-derivedDataPath", "-resultBundlePath", "-xctestrun", "-testPlan",
    "-archivePath", "-exportPath", "-exportOptionsPlist", "-only-testing", "-skip-testing",
    "-toolchain", "-xcconfig", "-testProductsPath", "-clonedSourcePackagesDirPath",
    "-packageCachePath", "-destination-timeout", "-parallel-testing-worker-count",
    "-maximum-concurrent-test-simulator-destinations", "-resultStreamPath", "-jobs",
    "-default-test-execution-time-allowance", "-maximum-test-execution-time-allowance",
    "-test-iterations", "-testLanguage", "-testRegion",
  ]

  private static func xcodebuildQueues(_ arguments: [String]) -> Bool {
    // The iOS simulator MCP keeps a WebDriverAgent test run alive for days.
    if arguments.contains(where: { $0.contains("WebDriverAgent") }) { return false }
    if arguments.contains(where: xcodebuildQueryFlags.contains) { return false }

    let actions = xcodebuildActions(arguments)
    if actions.contains(where: xcodebuildBuildingActions.contains) { return true }
    // No known action means xcodebuild's default, `build`. A bare word it does not know (the
    // value of an option missing from the table) is not taken for an action that builds
    // nothing, so a gap in the table errs towards queueing.
    return !actions.contains(where: xcodebuildIdleActions.contains)
  }

  /// The action a waiting line names for an xcodebuild holder: the first that builds, else
  /// the first bare word, else xcodebuild's default, `build`.
  static func xcodebuildAction(_ arguments: [String]) -> String {
    let actions = xcodebuildActions(arguments)
    return actions.first(where: xcodebuildBuildingActions.contains) ?? actions.first ?? "build"
  }

  /// The bare words left once options, their values and `KEY=VALUE` settings are skipped.
  private static func xcodebuildActions(_ arguments: [String]) -> [String] {
    var actions: [String] = []
    var index = arguments.startIndex
    while index < arguments.endIndex {
      let argument = arguments[index]
      if argument.hasPrefix("-") {
        index += xcodebuildValueOptions.contains(argument) ? 2 : 1
        continue
      }
      if !argument.contains("=") { actions.append(argument) }  // `KEY=VALUE` is a build setting
      index += 1
    }
    return actions
  }
}
