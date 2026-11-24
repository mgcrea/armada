import BuildSlotCore
import Foundation

/// `buildslot install` and `uninstall`: one line per shim on stdout. Exits 1 when a shim was
/// left out (a file of its name that Armada did not write, or a write that failed), so a
/// script that installs by hand notices.
enum InstallCommand {
  static func install(binDir: URL, helperPath: String) -> Int32 {
    let report = ShimInstaller.install(binDir: binDir, helperPath: helperPath)
    for tool in Tool.allCases {
      let path = binDir.appendingPathComponent(tool.rawValue).path
      if report.written.contains(tool) { print("\(path): wrote") }
      if report.unchanged.contains(tool) { print("\(path): unchanged") }
      if report.refused.contains(tool) { print("\(path): left alone: not written by Armada") }
    }
    if let error = report.error { say("buildslot: \(error).") }
    return report.error == nil && report.refused.isEmpty ? 0 : 1
  }

  static func uninstall(binDir: URL) -> Int32 {
    let removed = ShimInstaller.uninstall(binDir: binDir)
    var status: Int32 = 0
    for tool in Tool.allCases {
      let path = binDir.appendingPathComponent(tool.rawValue).path
      if removed.contains(tool) {
        print("\(path): removed")
      } else if RealTool.defaultIsShim(path) {
        say("buildslot: cannot remove \(path).")
        status = 1
      } else if FileManager.default.fileExists(atPath: path) {
        print("\(path): left alone: not written by Armada")
      }
    }
    return status
  }
}
