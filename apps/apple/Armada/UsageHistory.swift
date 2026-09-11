import Foundation

/// One reading of an account's windows, at the moment Claude Code took it.
///
/// Short keys because this file is appended to for as long as the app is installed
/// and every byte is repeated per sample. `t` is the cache's `fetchedAt`, never the
/// time Armada noticed it — that is what makes the same sample recognisable across
/// launches, and what the dedupe below compares.
nonisolated struct UsageSample: Codable, Sendable, Hashable {
  let t: Date
  /// Five-hour and seven-day percentages. Optional because a window can be absent
  /// from the cache, and a sample missing one should not be a sample missing both.
  let h: Int?
  let w: Int?
}

nonisolated private struct UsageHistoryFile: Codable {
  var version = 1
  var accounts: [String: [UsageSample]]
}

/// The recorded history of every account's windows.
///
/// **The first thing Armada writes.** Everything the forecast does works from a
/// single snapshot, so this is not needed to answer "when do I hit the wall" — it is
/// here to draw the week rather than assert it, which is the difference between a
/// claim and evidence.
///
/// `~/.claude` is never touched. The file lives under `AppInfo.supportDirectory`,
/// which is keyed by bundle id so a dev build cannot pollute an installed copy's
/// history.
@MainActor
@Observable
final class UsageHistory {
  static let shared = UsageHistory()

  /// Samples per `Account.id`, oldest first.
  private(set) var samples: [String: [UsageSample]] = [:]

  /// **Thirty days, pruned on load.** The weekly window is seven days, so a month
  /// covers four cycles — enough to see a pattern, and a hard ceiling on a file that
  /// otherwise grows for the life of the install. At the observed cache cadence this
  /// is a few thousand samples at most.
  static let retention: TimeInterval = 30 * 24 * 60 * 60

  static let fileName = "usage-history.json"

  var fileURL: URL? { AppInfo.supportDirectory?.appending(path: Self.fileName) }

  var totalSampleCount: Int { samples.values.reduce(0) { $0 + $1.count } }

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()

  /// ISO dates rather than epoch numbers: this file is small, and being able to read
  /// it in a text editor is worth more than the bytes when the question is "why does
  /// the chart show that".
  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  func load() {
    guard let url = fileURL, let data = try? Data(contentsOf: url),
      let file = try? Self.decoder.decode(UsageHistoryFile.self, from: data)
    else { return }
    let cutoff = Date.now.addingTimeInterval(-Self.retention)
    samples = file.accounts.mapValues { $0.filter { $0.t > cutoff }.sorted { $0.t < $1.t } }
      .filter { !$0.value.isEmpty }
  }

  /// Record a snapshot, if it is one that has not been seen.
  ///
  /// **Deduped on `fetchedAt`, and that is the whole design.** The poll in `Accounts`
  /// runs every 30 seconds, and the FSEvents watch fires more often than that again,
  /// while the cache they read moves on its own much slower schedule. Measured here
  /// on 2026-09-11: both `.claude.json` files were rewritten repeatedly across eight
  /// minutes of continuous Claude Code use, and `fetchedAtMs` did not move once. So
  /// without this the file would record the same reading hundreds of times a day and
  /// the chart would be a flat line made of duplicates.
  func record(_ snapshot: UsageSnapshot, for accountID: String) {
    guard let fetchedAt = snapshot.fetchedAt else { return }

    // **Normalised to the whole second before anything compares it.** The live value
    // comes from `fetchedAtMs` and carries milliseconds; the encoder writes ISO-8601
    // to the second and throws them away. Without this the reading loaded back from
    // disk is a fraction of a second behind the identical live one, the comparison
    // below never matches, and every launch silently appends a duplicate — which is
    // exactly what the first run of this did.
    let stamp = Date(timeIntervalSince1970: fetchedAt.timeIntervalSince1970.rounded(.down))

    var existing = samples[accountID] ?? []
    // Compare against the newest rather than scanning: samples arrive in order, and
    // the only duplicate that can occur is the one just seen.
    if let last = existing.last, last.t >= stamp { return }
    existing.append(
      UsageSample(
        t: stamp, h: snapshot.fiveHour?.utilization, w: snapshot.sevenDay?.utilization))
    let cutoff = Date.now.addingTimeInterval(-Self.retention)
    samples[accountID] = existing.filter { $0.t > cutoff }
    write()
  }

  /// Samples at or after `start`, for drawing one window's cycle.
  func samples(for accountID: String, since start: Date) -> [UsageSample] {
    (samples[accountID] ?? []).filter { $0.t >= start }
  }

  func clear() {
    samples = [:]
    guard let url = fileURL else { return }
    Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }
  }

  /// Encode on the main actor, write off it.
  ///
  /// The encode has to see `samples`, which is main-actor state; the write is disk
  /// I/O on a file that grows all month and has no business being on the thread
  /// drawing the window. Same split as the transcript scan in `TranscriptTitle`.
  private func write() {
    guard let url = fileURL,
      let data = try? Self.encoder.encode(UsageHistoryFile(accounts: samples))
    else { return }
    let directory = url.deletingLastPathComponent()
    Task.detached(priority: .utility) {
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try? data.write(to: url, options: .atomic)
    }
  }
}
