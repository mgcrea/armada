import Darwin
import Foundation
import os

/// Settings ▸ Supervisor ▸ Deliver messages: the switch that puts `MessageHook` into every Claude
/// Code account's `settings.json`, and takes it out again.
///
/// **Off by default, and the second write Armada makes to a vendor's configuration.** On, each
/// account's `settings.json` gains one Stop hook; off, exactly that hook goes, with a `Stop` list
/// or `hooks` object that held nothing else. Every other byte of the file stays as it was, which
/// `make unit` checks against real shapes. A running session picks the change up from its next
/// turn (measured on 2.1.273 against a project's settings file, 2026-09-16).
///
/// **Its own folder for everything else.** The script and every message live under Armada's
/// Application Support folder, keyed by bundle identifier, so a debug build and the installed one
/// each keep their own script, inbox and hook entry and neither removes the other's.
@MainActor
@Observable
final class MessageDelivery {
  static let shared = MessageDelivery()

  private static let logger = Logger(subsystem: "io.mgcrea.armada", category: "messages")

  nonisolated static let enabledKey = "armada.deliverMessages"
  nonisolated static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

  enum State: Equatable {
    case installed
    case removed
    case failed(String)
  }

  struct AccountState: Identifiable, Equatable {
    let id: String
    let name: String
    let state: State
  }

  /// What the last `sync` did in each account, for the pane.
  private(set) var accounts: [AccountState] = []

  private init() {}

  static var scriptURL: URL? {
    AppInfo.supportDirectory?.appending(path: "hooks", directoryHint: .isDirectory)
      .appending(path: MessageHook.scriptName, directoryHint: .notDirectory)
  }

  static var inboxURL: URL? {
    AppInfo.supportDirectory?.appending(path: "inbox", directoryHint: .isDirectory)
  }

  static var command: String? {
    guard let script = scriptURL, let inbox = inboxURL else { return nil }
    // Without the directory URL's trailing slash, which would put `//` in every inbox path.
    var root = inbox.path(percentEncoded: false)
    while root.count > 1, root.hasSuffix("/") { root.removeLast() }
    return MessageHook.command(script: script.path(percentEncoded: false), inbox: root)
  }

  /// Bring every account in line with the switch. Called when the switch moves and once the
  /// accounts have been discovered at launch, so an account added since gets the hook too.
  func sync() {
    let enabled = Self.isEnabled
    guard let script = Self.scriptURL, let inbox = Self.inboxURL, let command = Self.command else {
      accounts = Accounts.shared.all.map {
        AccountState(
          id: $0.id, name: $0.displayName,
          state: .failed("Armada could not find its Application Support folder."))
      }
      return
    }

    if enabled {
      if let failure = Self.prepare(script: script, inbox: inbox) {
        accounts = Accounts.shared.all.map {
          AccountState(id: $0.id, name: $0.displayName, state: .failed(failure))
        }
        return
      }
    } else {
      // Every hook still waiting reads `listening` from here, and stops once it is gone.
      try? FileManager.default.removeItem(at: inbox)
    }

    accounts = Accounts.shared.all.map { account in
      let state = Self.apply(
        enabled: enabled, settings: account.folder.settingsJSON, command: command,
        script: script.path(percentEncoded: false))
      if case .failed(let reason) = state {
        Self.logger.error(
          "hook not \(enabled ? "installed" : "removed", privacy: .public) in \(account.folder.path, privacy: .public): \(reason, privacy: .public)"
        )
      }
      return AccountState(id: account.id, name: account.displayName, state: state)
    }
  }

  /// Whether `account`'s hook is in place, as the last `sync` left it.
  func isInstalled(accountID: String) -> Bool {
    accounts.first { $0.id == accountID }?.state == .installed
  }

  /// The script, rewritten on every sync so an update to Armada reaches it, and the inbox, 0700.
  nonisolated private static func prepare(script: URL, inbox: URL) -> String? {
    let fileManager = FileManager.default
    do {
      for directory in [script.deletingLastPathComponent(), inbox] {
        try fileManager.createDirectory(
          at: directory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
      }
      try Data(MessageHook.script.utf8).write(to: script, options: .atomic)
      try fileManager.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: script.path(percentEncoded: false))
      return nil
    } catch {
      return "Armada could not write its hook script: \(error.localizedDescription)"
    }
  }

  /// One account's `settings.json`, under the same `<file>.lock` `ClaudeTrust` takes.
  nonisolated private static func apply(
    enabled: Bool, settings: URL, command: String, script: String,
    lockBudget: Duration = .milliseconds(400)
  ) -> State {
    let file = settings.path(percentEncoded: false)
    let exists = FileManager.default.fileExists(atPath: file)
    if !enabled, !exists { return .removed }

    let lock = file + ".lock"
    let deadline = ContinuousClock.now + lockBudget
    while mkdir(lock, 0o755) != 0 {
      guard errno == EEXIST, ContinuousClock.now < deadline else {
        return .failed("\(lock) is held, most likely by a Claude Code writing the file")
      }
      usleep(25_000)
    }
    defer { rmdir(lock) }

    // Written beside the real file, so a settings.json symlinked from a dotfiles repository stays
    // a symlink.
    let target =
      realpath(file, nil).map { pointer in
        defer { free(pointer) }
        return String(cString: pointer)
      } ?? file
    let data = exists ? FileManager.default.contents(atPath: target) : nil
    if exists, data == nil { return .failed("could not read \(target)") }

    let edit =
      enabled
      ? MessageHook.installing(data, command: command, script: script)
      : MessageHook.removing(data ?? Data(), script: script)
    switch edit {
    case .unchanged:
      return enabled ? .installed : .removed
    case .refused(let reason):
      return .failed(reason)
    case .edited(let edited):
      if exists {
        if let failure = ClaudeTrust.replace(target, with: edited) { return .failed(failure) }
      } else {
        guard
          FileManager.default.createFile(
            atPath: target, contents: edited, attributes: [.posixPermissions: 0o644])
        else { return .failed("could not create \(target)") }
      }
      return enabled ? .installed : .removed
    }
  }
}

/// One session's inbox: where `armada_send_message` writes, and how it tells whether the hook is
/// waiting.
nonisolated enum SessionInbox {
  /// Written as `.tmp` and renamed, so the hook never claims half a message. The name sorts by
  /// time, which is the order the hook prints several in.
  static func write(_ text: String, session: String, in root: URL) throws -> URL {
    let directory = root.appending(path: session, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let stamp = String(format: "%015d", Int64(Date().timeIntervalSince1970 * 1000))
    let name = "\(stamp)-\(UUID().uuidString.lowercased())"
    let temporary = directory.appending(path: name + ".tmp", directoryHint: .notDirectory)
    let final = directory.appending(path: name + ".msg", directoryHint: .notDirectory)
    guard
      FileManager.default.createFile(
        atPath: temporary.path(percentEncoded: false), contents: Data(text.utf8),
        attributes: [.posixPermissions: 0o600])
    else { throw CocoaError(.fileWriteUnknown) }
    guard rename(temporary.path(percentEncoded: false), final.path(percentEncoded: false)) == 0
    else {
      unlink(temporary.path(percentEncoded: false))
      throw CocoaError(.fileWriteUnknown)
    }
    return final
  }

  /// Whether a hook run is waiting for `session`: the pid in `listening` is alive and is a child
  /// of the session's own `claude`. The parent check is what keeps a recycled pid from reading as
  /// a listener.
  static func isListening(session: String, sessionPID: pid_t, in root: URL) -> Bool {
    let marker = root.appending(path: session, directoryHint: .isDirectory)
      .appending(path: "listening", directoryHint: .notDirectory)
    guard let text = try? String(contentsOf: marker, encoding: .utf8),
      let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1
    else { return false }
    return ProcessAncestry.parent(of: pid) == sessionPID
  }
}
