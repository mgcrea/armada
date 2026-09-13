import AppKit
import Foundation

/// Where `codex` is, mirroring `ClaudeControl.executable()`.
///
/// Same trap as the Claude lookup — **a GUI process inherits no login `PATH`** — and
/// one extra that is specific to Codex: on this Mac there is no `codex` on `PATH` at
/// all. The CLI ships *inside the Codex app*, at
/// `/Applications/ChatGPT.app/Contents/Resources/codex` (`codex-cli 0.153.4`, measured
/// 2026-09-13), which is the copy the app itself runs. So the app bundle is a search
/// location rather than a curiosity: without it, a Mac whose Codex sessions all come
/// from the app would show a New Session button that could never start one.
///
/// The bundle is resolved through LaunchServices by id rather than by the path above,
/// so a Codex app somewhere other than `/Applications` is still found.
/// `CodexIcon.bundleID` is the same id, and it is `com.openai.codex` — confirmed
/// against `ChatGPT.app/Contents/Info.plist` on 2026-09-13. The two agree because the
/// app that draws the icon is the app that carries the binary.
///
/// **And the VS Code extension carries a third copy**, at
/// `~/.vscode/extensions/openai.chatgpt-<version>/bin/<arch>/codex`, which is the one
/// that matters on a Mac running Codex in the editor with no ChatGPT.app installed —
/// the case `CodexIcon` already documents for the icon. Six versions of the extension
/// are installed here, so the newest name wins; any of them would work, and the newest
/// is the one the editor itself is running.
nonisolated enum CodexCLI {
  static func executable() -> URL? {
    let fileManager = FileManager.default
    let home = fileManager.homeDirectoryForCurrentUser

    var candidates: [URL] = []
    if let path = ProcessInfo.processInfo.environment["PATH"] {
      candidates += path.split(separator: ":").map {
        URL(filePath: String($0)).appending(path: "codex", directoryHint: .notDirectory)
      }
    }
    candidates += [
      home.appending(path: ".local/bin/codex", directoryHint: .notDirectory),
      URL(filePath: "/opt/homebrew/bin/codex"),
      URL(filePath: "/usr/local/bin/codex"),
    ]
    // Read on the main actor's behalf but not from it — `NSWorkspace` is safe to ask
    // from any thread, and this whole enum is called off the UI's critical path.
    if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: CodexIcon.bundleID) {
      candidates.append(
        app.appending(path: "Contents/Resources/codex", directoryHint: .notDirectory))
    }

    candidates += extensionCopies(home: home)

    return candidates.first { fileManager.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
  }

  /// Every `codex` shipped inside an installed OpenAI VS Code extension, newest first.
  ///
  /// Sorted on the directory name, which carries the version
  /// (`openai.chatgpt-26.908.40401-darwin-arm64`), and left lexicographic on purpose:
  /// these are zero-padded date-like builds where that is the right order, and this is
  /// the last resort in the list rather than a choice anything depends on.
  ///
  /// The architecture directory is enumerated rather than named, so an Intel Mac's
  /// `macos-x86_64` is found by the same code that finds `macos-aarch64` here.
  private static func extensionCopies(home: URL) -> [URL] {
    let fileManager = FileManager.default
    let root = home.appending(path: ".vscode/extensions", directoryHint: .isDirectory)
    let names = (try? fileManager.contentsOfDirectory(atPath: root.path(percentEncoded: false)))
    guard let names else { return [] }

    return
      names
      .filter { $0.hasPrefix("openai.chatgpt-") }
      .sorted(by: >)
      .flatMap { name -> [URL] in
        let binaries = root.appending(path: name, directoryHint: .isDirectory)
          .appending(path: "bin", directoryHint: .isDirectory)
        let architectures =
          (try? fileManager.contentsOfDirectory(atPath: binaries.path(percentEncoded: false))) ?? []
        return architectures.sorted().map {
          binaries.appending(path: $0, directoryHint: .isDirectory)
            .appending(path: "codex", directoryHint: .notDirectory)
        }
      }
  }
}
