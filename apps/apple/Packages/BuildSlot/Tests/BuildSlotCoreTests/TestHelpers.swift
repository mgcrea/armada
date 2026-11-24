import BuildSlotCore
import Foundation

/// Paths under a fresh folder of their own, so tests running in parallel never share a lock.
func tempPaths() -> BuildSlotPaths {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("buildslot-tests-\(UUID().uuidString)", isDirectory: true)
  return BuildSlotPaths(
    lockRoot: root.appendingPathComponent("locks", isDirectory: true),
    settingsFile: root.appendingPathComponent("settings.json"))
}

/// Takes a POSIX record lock on `argv[2]` with `lockf` (fcntl `F_SETLK`, the family the tool
/// uses, unlike `flock`). In `hold` mode it writes the record JSON from `argv[3]` when given,
/// prints `locked`, then keeps the lock for 30 s; in `try` mode it prints whether it got the lock
/// and exits, which releases it. `{pid}` in the path and a record `pid` of 0 become the helper's
/// own pid, which the test cannot know before it starts.
private let lockScript = """
  import fcntl, json, os, sys, time
  mode, path = sys.argv[1], sys.argv[2].replace('{pid}', str(os.getpid()))
  f = open(path, 'a+')
  try:
      fcntl.lockf(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
  except OSError:
      print('busy', flush=True)
      sys.exit(0)
  if mode == 'try':
      print('locked', flush=True)
      sys.exit(0)
  if len(sys.argv) > 3:
      record = json.loads(sys.argv[3])
      if record['pid'] == 0:
          record['pid'] = os.getpid()
      f.truncate(0)
      f.write(json.dumps(record))
      f.flush()
  print('locked', flush=True)
  time.sleep(30)
  """

/// Starts the lock script and returns it with the first line it printed.
private func runLockScript(_ arguments: [String]) -> (Process, String) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
  process.arguments = ["-I", "-c", lockScript] + arguments
  let pipe = Pipe()
  process.standardOutput = pipe
  try! process.run()
  var output = Data()
  while !output.contains(UInt8(ascii: "\n")) {
    let chunk = pipe.fileHandleForReading.availableData
    if chunk.isEmpty { break }
    output.append(chunk)
  }
  let line = String(decoding: output, as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return (process, line)
}

/// A second process holding `url`'s lock, because `F_GETLK` never reports the caller's own locks.
/// Returns once the lock is taken; the test stops it.
func holdLock(_ url: URL, record: SlotRecord?) -> Process {
  var arguments = ["hold", url.path]
  if let record { arguments.append(String(decoding: try! record.encoded(), as: UTF8.self)) }
  let (process, line) = runLockScript(arguments)
  precondition(line == "locked", "lock helper said \(line)")
  return process
}

/// Whether another process can take `url`'s lock right now.
func otherProcessCanLock(_ url: URL) -> Bool {
  let (process, line) = runLockScript(["try", url.path])
  process.waitUntilExit()
  return line == "locked"
}

func stop(_ process: Process) {
  process.terminate()
  process.waitUntilExit()
}

func record(pid: Int32, startedAt: Date? = .now, waitingSince: Date? = nil) -> SlotRecord {
  SlotRecord(
    pid: pid, processStart: nil, startedAt: startedAt, waitingSince: waitingSince,
    cwd: "/u/p/valise", label: "valise", tool: "swift", argv: ["swift", "test"])
}
