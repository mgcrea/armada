import BuildSlotCore
import Darwin
import Foundation

// `buildslot --as swift|xcodebuild …` is what the shims run; `run` queues any command, by hand
// or in tests; `status` shows the queue. Bad usage exits 64, EX_USAGE.

let usage = """
  usage: buildslot --as swift|xcodebuild [arguments...]
         buildslot run -- <command> [arguments...]
         buildslot status [--json]
         buildslot install [--bin-dir DIR]
         buildslot uninstall [--bin-dir DIR]

  """

func usageError() -> Never {
  FileHandle.standardError.write(Data(usage.utf8))
  exit(64)
}

/// Queues `executable` unless something lets it straight through, then runs it holding the
/// slot. Every pass-through execs the tool, so nothing of this process stays behind it.
/// `argv` is what the holder record shows; `arguments` follow the executable's own path.
func queueAndRun(
  tool: String, executable: String, arguments: [String], argv: [String], queues: Bool
) -> Never {
  let environment = ProcessInfo.processInfo.environment
  let childArguments = [executable] + arguments
  if environment["ARMADA_BUILDSLOT"] == "off" || !queues {
    ChildRunner.replace(path: executable, arguments: childArguments)
  }

  let paths = BuildSlotPaths.standard(environment: environment)
  let settings = BuildSlotSettings.load(from: paths.settingsFile)
  // Only from a lock folder that passes the checks: another account's records must not let a
  // build through. A folder refused or not made yet has no holders, and the acquire below says
  // why it runs unqueued. Without sweeping, which is the acquire's job.
  let holders =
    (try? paths.verifyDirectories()) == nil
    ? []
    : QueueReader.read(paths, slotCount: settings.slots, ownPID: getpid(), sweep: false)
      .holders.map(\.record)
  let nested = Nesting.passesThrough(
    environment: environment, ancestors: ProcessTree.ancestors(of: getpid()),
    cwd: currentDirectory(), holders: holders,
    workingTreeRoot: { HolderLabel.workingTreeRoot(of: $0) })
  if nested { ChildRunner.replace(path: executable, arguments: childArguments) }

  let held = Acquirer.acquire(tool: tool, argv: argv, paths: paths)
  guard held.lock != nil else {
    // Unqueued, or every slot still busy at the slot cap: the build runs anyway, so whatever it
    // starts must pass through rather than queue behind other holders. Exec keeps this pid, so
    // the ancestry rule still finds it.
    var unqueued = environment
    unqueued[Nesting.holderVariable] = String(getpid())
    ChildRunner.replace(path: executable, arguments: childArguments, environment: unqueued)
  }
  withExtendedLifetime(held) {
    ChildRunner.run(path: executable, arguments: childArguments, environment: environment)
  }
}

/// `command` as the shell would find it: a path as given, a bare name on `PATH`.
func resolveOnPath(_ command: String) -> String? {
  if command.contains("/") { return command }
  let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
  for directory in path.split(separator: ":") {
    let candidate = "\(directory)/\(command)"
    if RealTool.isExecutableFile(candidate) { return candidate }
  }
  return nil
}

/// This binary's own path, so the real-tool walk never picks a link back to it.
func ownExecutablePath() -> String {
  Bundle.main.executablePath ?? CommandLine.arguments[0]
}

/// `path` with every link resolved, as the shims must call the binary wherever it really is.
func resolvedPath(_ path: String) -> String {
  guard let real = realpath(path, nil) else { return path }
  defer { free(real) }
  return String(cString: real)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "--as":
  guard arguments.count >= 2, let tool = Tool(rawValue: arguments[1]) else { usageError() }
  let toolArguments = Array(arguments.dropFirst(2))
  // The shims live in `~/.local/bin` and nowhere else; a shim elsewhere is still caught by its
  // marker.
  let shimDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/bin").path
  let executable = RealTool.resolve(
    tool, path: ProcessInfo.processInfo.environment["PATH"] ?? "", skipping: shimDirectory,
    helperPath: ownExecutablePath())
  queueAndRun(
    tool: tool.rawValue, executable: executable, arguments: toolArguments,
    argv: [tool.rawValue] + toolArguments,
    queues: Invocation.queues(tool, arguments: toolArguments))

case "run":
  var command = arguments.dropFirst()
  if command.first == "--" { command = command.dropFirst() }
  guard let name = command.first else { usageError() }
  guard let executable = resolveOnPath(name) else {
    say("buildslot: \(name): command not found.")
    exit(127)
  }
  queueAndRun(
    tool: (name as NSString).lastPathComponent, executable: executable,
    arguments: Array(command.dropFirst()), argv: Array(command), queues: true)

case "status":
  let options = arguments.dropFirst()
  guard options.allSatisfy({ $0 == "--json" }) else { usageError() }
  exit(StatusCommand.run(json: options.contains("--json")))

case "install", "uninstall":
  let options = Array(arguments.dropFirst())
  let binDir: URL
  switch options.count {
  case 0:
    binDir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".local/bin", isDirectory: true)
  case 2 where options[0] == "--bin-dir":
    binDir = URL(fileURLWithPath: options[1], isDirectory: true)
  default:
    usageError()
  }
  exit(
    arguments[0] == "install"
      ? InstallCommand.install(binDir: binDir, helperPath: resolvedPath(ownExecutablePath()))
      : InstallCommand.uninstall(binDir: binDir))

default:
  usageError()
}
