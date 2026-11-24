import BuildSlotCore
import Foundation
import Testing

// The shims and their installer: the installer never overwrites a file it did not write, and a
// shim whose helper is gone still runs the real tool, so deleting Armada never breaks a build.
// The shim tests run the written script itself under /bin/sh.
struct ShimInstallerTests {
  private let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("buildslot-shims-\(UUID().uuidString)", isDirectory: true)

  private var binDir: URL { root.appendingPathComponent("bin", isDirectory: true) }

  private func dir(_ name: String) throws -> URL {
    let url = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func executable(_ url: URL, _ content: String) throws {
    try Data(content.utf8).write(to: url)
    #expect(chmod(url.path, 0o755) == 0)
  }

  private func contents(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
  }

  /// Runs `executable` with `arguments` and only `PATH` in its environment; returns its status
  /// and stdout.
  private func run(_ executable: URL, _ arguments: [String], path: String) throws
    -> (status: Int32, output: String)
  {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = ["PATH": path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  @Test func writesBothShims() throws {
    let report = ShimInstaller.install(binDir: binDir, helperPath: "/A/buildslot")
    #expect(report == InstallReport(written: [.swift, .xcodebuild], unchanged: [], refused: []))
    for tool in Tool.allCases {
      let url = binDir.appendingPathComponent(tool.rawValue)
      #expect(access(url.path, X_OK) == 0)
      let lines = try contents(url).split(separator: "\n", omittingEmptySubsequences: false)
      #expect(lines.prefix(2) == ["#!/bin/sh", "# \(ShimInstaller.marker)"])
    }
    #expect(
      ShimInstaller.marker
        == "armada-buildslot-shim v1 — written by Armada; Armada repairs or removes this file.")
  }

  @Test func secondInstallUnchanged() {
    _ = ShimInstaller.install(binDir: binDir, helperPath: "/A/buildslot")
    let report = ShimInstaller.install(binDir: binDir, helperPath: "/A/buildslot")
    #expect(report == InstallReport(written: [], unchanged: [.swift, .xcodebuild], refused: []))
  }

  @Test func repointsMovedHelper() {
    _ = ShimInstaller.install(binDir: binDir, helperPath: "/A/buildslot")
    let report = ShimInstaller.install(binDir: binDir, helperPath: "/B/buildslot")
    #expect(report.written == [.swift, .xcodebuild])
    #expect(ShimInstaller.installedHelperPath(binDir: binDir, tool: .swift) == "/B/buildslot")
    #expect(ShimInstaller.installedHelperPath(binDir: binDir, tool: .xcodebuild) == "/B/buildslot")
  }

  @Test func installRefusesForeignFile() throws {
    let bin = try dir("bin")
    let foreign = bin.appendingPathComponent("swift")
    try executable(foreign, "#!/bin/sh\necho mine\n")
    let report = ShimInstaller.install(binDir: binDir, helperPath: "/A/buildslot")
    #expect(report == InstallReport(written: [.xcodebuild], unchanged: [], refused: [.swift]))
    #expect(try contents(foreign) == "#!/bin/sh\necho mine\n")
    #expect(ShimInstaller.installedHelperPath(binDir: binDir, tool: .swift) == nil)
  }

  @Test func uninstallKeepsForeignFile() throws {
    _ = ShimInstaller.install(binDir: binDir, helperPath: "/A/buildslot")
    let foreign = binDir.appendingPathComponent("swift")
    try FileManager.default.removeItem(at: foreign)
    try executable(foreign, "#!/bin/sh\necho mine\n")
    #expect(ShimInstaller.uninstall(binDir: binDir) == [.xcodebuild])
    #expect(try contents(foreign) == "#!/bin/sh\necho mine\n")
    #expect(
      !FileManager.default.fileExists(atPath: binDir.appendingPathComponent("xcodebuild").path))
  }

  @Test func quotesHelperPath() throws {
    let helperDir = try dir("it's here")
    let helper = helperDir.appendingPathComponent("buildslot")
    try executable(helper, "#!/bin/sh\necho \"$@\"\n")
    _ = ShimInstaller.install(binDir: binDir, helperPath: helper.path)
    #expect(ShimInstaller.installedHelperPath(binDir: binDir, tool: .swift) == helper.path)
    let result = try run(binDir.appendingPathComponent("swift"), ["build"], path: "/usr/bin:/bin")
    #expect(result.output == "--as swift build\n")
  }

  @Test func shimRunsHelper() throws {
    let helper = try dir("helper").appendingPathComponent("buildslot")
    try executable(helper, "#!/bin/sh\necho HELPER \"$@\"\n")
    _ = ShimInstaller.install(binDir: binDir, helperPath: helper.path)
    let result = try run(
      binDir.appendingPathComponent("swift"), ["test"], path: "\(binDir.path):/usr/bin")
    #expect(result.output == "HELPER --as swift test\n")
  }

  @Test func shimFallsBackWhenHelperMissing() throws {
    let realDir = try dir("real")
    try executable(realDir.appendingPathComponent("swift"), "#!/bin/sh\necho REAL \"$@\"\n")
    _ = ShimInstaller.install(binDir: binDir, helperPath: root.appendingPathComponent("gone").path)
    let result = try run(
      binDir.appendingPathComponent("swift"), ["build"], path: "\(binDir.path):\(realDir.path)")
    #expect(result == (0, "REAL build\n"))
  }

  @Test func shimFallbackSkipsItselfViaSymlinkedDir() throws {
    let realDir = try dir("real")
    try executable(realDir.appendingPathComponent("swift"), "#!/bin/sh\necho REAL \"$@\"\n")
    _ = ShimInstaller.install(binDir: binDir, helperPath: root.appendingPathComponent("gone").path)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binDir)
    let result = try run(
      link.appendingPathComponent("swift"), ["build"], path: "\(link.path):\(realDir.path)")
    #expect(result == (0, "REAL build\n"))
  }

  @Test func commandInstallsPointingAtItself() throws {
    let binary = URL(fileURLWithPath: BinaryTests.binary)
    let installed = try run(binary, ["install", "--bin-dir", binDir.path], path: "/usr/bin")
    #expect(installed.status == 0)
    #expect(
      installed.output
        == "\(binDir.path)/swift: wrote\n\(binDir.path)/xcodebuild: wrote\n")
    let real = binary.resolvingSymlinksInPath().path
    #expect(ShimInstaller.installedHelperPath(binDir: binDir, tool: .swift) == real)

    let removed = try run(binary, ["uninstall", "--bin-dir", binDir.path], path: "/usr/bin")
    #expect(removed.status == 0)
    #expect(
      removed.output == "\(binDir.path)/swift: removed\n\(binDir.path)/xcodebuild: removed\n")
  }

  @Test func fallbackSkipsAnotherShim() throws {
    // Two copies of the shim with the helper gone must not exec each other in a loop.
    let otherDir = try dir("other")
    let realDir = try dir("real")
    try executable(realDir.appendingPathComponent("swift"), "#!/bin/sh\necho REAL \"$@\"\n")
    let gone = root.appendingPathComponent("gone").path
    _ = ShimInstaller.install(binDir: binDir, helperPath: gone)
    _ = ShimInstaller.install(binDir: otherDir, helperPath: gone)
    let result = try run(
      binDir.appendingPathComponent("swift"), ["build"],
      path: "\(binDir.path):\(otherDir.path):\(realDir.path)")
    #expect(result == (0, "REAL build\n"))
  }
}
