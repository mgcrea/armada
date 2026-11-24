import BuildSlotCore
import Foundation
import Testing

// Finding the real swift or xcodebuild behind the shims: a shim that found itself, or another
// shim, would run the queue in a loop instead of the build.
struct RealToolTests {
  private let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("buildslot-realtool-\(UUID().uuidString)", isDirectory: true)

  private func dir(_ name: String) throws -> String {
    let url = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
  }

  @discardableResult
  private func executable(_ path: String, _ content: String = "#!/bin/sh\nexit 0\n") throws
    -> String
  {
    try Data(content.utf8).write(to: URL(fileURLWithPath: path))
    #expect(chmod(path, 0o755) == 0)
    return path
  }

  private var helper: String { root.appendingPathComponent("helper/buildslot").path }

  private func prepareHelper() throws {
    _ = try dir("helper")
    try executable(helper, "not a shim, the helper binary")
  }

  @Test func skipsShimDirectory() throws {
    try prepareHelper()
    let shimDir = try dir("shims")
    let realDir = try dir("real")
    try executable(shimDir + "/swift")
    let real = try executable(realDir + "/swift")
    #expect(
      RealTool.resolve(
        .swift, path: "\(shimDir):\(realDir)", skipping: shimDir, helperPath: helper) == real)
  }

  @Test func skipsMarkerShimElsewhere() throws {
    try prepareHelper()
    let otherDir = try dir("other")
    let realDir = try dir("real")
    try executable(otherDir + "/swift", "#!/bin/sh\n# \(ShimMarker.text) - written by Armada\n")
    let real = try executable(realDir + "/swift")
    #expect(
      RealTool.resolve(.swift, path: "\(otherDir):\(realDir)", skipping: nil, helperPath: helper)
        == real)
  }

  @Test func skipsSymlinkToHelper() throws {
    try prepareHelper()
    let otherDir = try dir("other")
    let realDir = try dir("real")
    try FileManager.default.createSymbolicLink(
      atPath: otherDir + "/xcodebuild", withDestinationPath: helper)
    let real = try executable(realDir + "/xcodebuild")
    #expect(
      RealTool.resolve(
        .xcodebuild, path: "\(otherDir)::\(realDir)", skipping: nil, helperPath: helper) == real)
  }

  @Test func skipsWhatIsNotExecutable() throws {
    try prepareHelper()
    let otherDir = try dir("other")
    let realDir = try dir("real")
    try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: otherDir + "/swift"))
    try FileManager.default.createDirectory(
      atPath: realDir + "/swift", withIntermediateDirectories: true)
    #expect(
      RealTool.resolve(.swift, path: "\(otherDir):\(realDir)", skipping: nil, helperPath: helper)
        == "/usr/bin/swift")
  }

  @Test func fallsBackToUsrBin() {
    #expect(
      RealTool.resolve(.swift, path: "", skipping: nil, helperPath: helper) == "/usr/bin/swift")
    #expect(
      RealTool.resolve(.xcodebuild, path: "", skipping: nil, helperPath: helper)
        == "/usr/bin/xcodebuild")
  }
}
