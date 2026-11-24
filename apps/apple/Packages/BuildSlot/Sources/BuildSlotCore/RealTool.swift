import Darwin
import Foundation

/// The text every shim carries near its top, which tells a shim from a real tool and from a
/// user's own file of the same name. The installer builds the shim's marker line from it.
public enum ShimMarker {
  public static let text = "armada-buildslot-shim v1"
}

/// The real `swift` or `xcodebuild` behind the shims, found the way the shim script finds it
/// when Armada is gone: walk `PATH`, skip the shims' folder, any other shim and anything that
/// is this binary, and fall back to Apple's stubs in `/usr/bin`, which honour `DEVELOPER_DIR`
/// and `xcode-select`. A shim that resolved to itself or another shim would run the queue in a
/// loop instead of the build.
public enum RealTool {
  public static func resolve(
    _ tool: Tool, path: String, skipping shimDirectory: String?, helperPath: String,
    isShim: (String) -> Bool = RealTool.defaultIsShim
  ) -> String {
    let skippedDirectory = shimDirectory.flatMap(resolved)
    let helper = resolved(helperPath)
    for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
      let directory = String(directory)
      if let skippedDirectory, resolved(directory) == skippedDirectory { continue }
      let candidate =
        directory.hasSuffix("/") ? directory + tool.rawValue : "\(directory)/\(tool.rawValue)"
      guard isExecutableFile(candidate), !isShim(candidate) else { continue }
      if let helper, resolved(candidate) == helper { continue }
      return candidate
    }
    return "/usr/bin/" + tool.rawValue
  }

  /// Whether the file's first 256 bytes carry the marker. A shim writes it on its second line.
  public static func defaultIsShim(_ path: String) -> Bool {
    let fd = open(path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var buffer = [UInt8](repeating: 0, count: 256)
    let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
    guard count > 0 else { return false }
    return Data(buffer[0..<count]).range(of: Data(ShimMarker.text.utf8)) != nil
  }

  /// A regular file (after following links) this user may execute. Public so `buildslot run`
  /// finds its command by the same test.
  public static func isExecutableFile(_ path: String) -> Bool {
    var info = stat()
    guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
    return access(path, X_OK) == 0
  }

  private static func resolved(_ path: String) -> String? {
    guard let real = realpath(path, nil) else { return nil }
    defer { free(real) }
    return String(cString: real)
  }
}
