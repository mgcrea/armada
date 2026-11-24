import Darwin
import Foundation

/// What one install did to each shim.
public struct InstallReport: Equatable, Sendable {
  public var written: [Tool]
  public var unchanged: [Tool]
  /// A file of the shim's name without the marker: the user's own, left as it was.
  public var refused: [Tool]
  /// Why the install stopped short, when it did.
  public var error: String?

  public init(
    written: [Tool] = [], unchanged: [Tool] = [], refused: [Tool] = [], error: String? = nil
  ) {
    self.written = written
    self.unchanged = unchanged
    self.refused = refused
    self.error = error
  }
}

/// Writes and removes the `swift` and `xcodebuild` shims. Shared by the app and
/// `buildslot install`, so both apply the same rules: never touch a file without the marker,
/// rewrite a shim whose helper moved, remove only shims.
///
/// The shims are `sh` scripts rather than symlinks to the helper: a shell that hashed a
/// symlink's path fails the command once Armada is deleted or moved, where a script checks
/// first and runs the real tool unqueued.
public enum ShimInstaller {
  public static let marker =
    "\(ShimMarker.text) — written by Armada; Armada repairs or removes this file."

  /// The shim for `tool`, calling the helper at `helperPath`.
  ///
  /// Without the helper it walks `PATH` as the Swift side does (`RealTool`): it skips its own
  /// folder, compared after resolving links, and any other shim, since two shims whose helper
  /// is gone would otherwise exec each other in a loop. The commands it needs are named by
  /// full path, as the `PATH` it was given may lack `/usr/bin`. `set -f` keeps a `*` in a `PATH`
  /// entry from globbing.
  public static func script(for tool: Tool, helperPath: String) -> String {
    let name = tool.rawValue
    return """
      #!/bin/sh
      # \(marker)
      b=\(shellQuoted(helperPath))
      [ -f "$b" ] && [ -x "$b" ] && exec "$b" --as \(name) "$@"
      # Armada is gone: run the real \(name), unqueued.
      self_dir=$(CDPATH= cd -- "$(/usr/bin/dirname -- "$0")" && pwd -P)
      set -f; IFS=:
      for d in $PATH; do
        [ -n "$d" ] && [ -f "$d/\(name)" ] && [ -x "$d/\(name)" ] || continue
        [ "$(CDPATH= cd -- "$d" 2>/dev/null && pwd -P)" = "$self_dir" ] && continue
        /usr/bin/head -c 256 "$d/\(name)" 2>/dev/null | /usr/bin/grep -qF '\(ShimMarker.text)' && continue
        exec "$d/\(name)" "$@"
      done
      exec /usr/bin/\(name) "$@"

      """
  }

  /// Writes both shims into `binDir`, creating it if missing. Each is written whole to a
  /// temporary file and renamed into place, so a shell running the shim never reads half of one.
  public static func install(binDir: URL, helperPath: String) -> InstallReport {
    var report = InstallReport()
    do {
      try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    } catch {
      report.error = "cannot create \(binDir.path) (\(describe(error)))"
      return report
    }
    for tool in Tool.allCases {
      let url = binDir.appendingPathComponent(tool.rawValue)
      let script = script(for: tool, helperPath: helperPath)
      if exists(url.path) {
        guard RealTool.defaultIsShim(url.path) else {
          report.refused.append(tool)
          continue
        }
        if (try? Data(contentsOf: url)) == Data(script.utf8) {
          report.unchanged.append(tool)
          continue
        }
      }
      if let error = write(script, to: url) {
        report.error = error
        return report
      }
      report.written.append(tool)
    }
    return report
  }

  /// Removes the shims from `binDir` and returns the tools it removed. A file without the
  /// marker stays.
  public static func uninstall(binDir: URL) -> [Tool] {
    Tool.allCases.filter { tool in
      let path = binDir.appendingPathComponent(tool.rawValue).path
      return RealTool.defaultIsShim(path) && unlink(path) == 0
    }
  }

  /// Removes only the shims calling `helperPath`, both sides compared with links resolved, and
  /// returns the tools it removed. A Debug build switching off uses it, so the Release build's
  /// shims stay.
  public static func uninstall(binDir: URL, onlyPointingAt helperPath: String) -> [Tool] {
    let own = resolved(helperPath)
    return Tool.allCases.filter { tool in
      guard let installed = installedHelperPath(binDir: binDir, tool: tool),
        resolved(installed) == own
      else { return false }
      return unlink(binDir.appendingPathComponent(tool.rawValue).path) == 0
    }
  }

  /// Whether an app at `bundlePath` runs from somewhere it will not stay: translocated by
  /// Gatekeeper, or on a mounted disk image. Shims pointing there break once it is gone.
  public static func isTransientLocation(_ bundlePath: String) -> Bool {
    bundlePath.contains("/AppTranslocation/") || bundlePath.hasPrefix("/Volumes/")
  }

  /// The helper path the installed shim for `tool` calls, or nil when there is no shim.
  public static func installedHelperPath(binDir: URL, tool: Tool) -> String? {
    let path = binDir.appendingPathComponent(tool.rawValue).path
    guard RealTool.defaultIsShim(path),
      let text = try? String(contentsOfFile: path, encoding: .utf8)
    else { return nil }
    for line in text.split(separator: "\n") where line.hasPrefix("b='") && line.hasSuffix("'") {
      return line.dropFirst(3).dropLast().replacingOccurrences(of: #"'\''"#, with: "'")
    }
    return nil
  }

  /// Single quotes keep every character as it is but `'`, which closes the quote, escapes and
  /// reopens it.
  private static func shellQuoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
  }

  /// `path` with every link resolved, or as given when it does not resolve.
  private static func resolved(_ path: String) -> String {
    guard let real = realpath(path, nil) else { return path }
    defer { free(real) }
    return String(cString: real)
  }

  /// Whether anything is at `path`, a dangling link included: a link of the shim's name is the
  /// user's, unless it leads to a shim.
  private static func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
  }

  /// Writes `script` as an executable file at `url`; returns why it could not.
  private static func write(_ script: String, to url: URL) -> String? {
    let temporary = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    do {
      try Data(script.utf8).write(to: temporary)
    } catch {
      return "cannot write \(temporary.path) (\(describe(error)))"
    }
    // Explicitly, since the file was created under the umask.
    if chmod(temporary.path, 0o755) != 0 || rename(temporary.path, url.path) != 0 {
      let reason = String(cString: strerror(errno))
      unlink(temporary.path)
      return "cannot write \(url.path) (\(reason))"
    }
    return nil
  }

  private static func describe(_ error: any Error) -> String {
    let error = error as NSError
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
      underlying.domain == NSPOSIXErrorDomain
    {
      return String(cString: strerror(Int32(underlying.code)))
    }
    return error.localizedDescription
  }
}
