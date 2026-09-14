import SwiftUI

/// The one plan limit whose figure rides beside the menu bar glyph.
///
/// **Named by account, window and model rather than by a row's id.** The Usage pane
/// lists windows from the `limits` array, the header strips from the two flat keys,
/// and the two id schemes share nothing — so a star keyed on either would light in
/// one place and not the other for what is the same window. Account plus length plus
/// model is what both of them can say.
///
/// One at a time, and that is the whole point of it: the glyph is 18pt, and a second
/// figure beside it would be a row of numbers nobody can tell apart at a glance.
nonisolated struct MenuBarLimit: Sendable, Hashable {
  let accountID: String
  let length: UsageWindowLength
  /// `UsageLimit.scopeModelName` — "Fable". Nil for an account-wide window.
  let model: String?

  static let defaultsKey = "armada.menuBarLimit"

  init(accountID: String, length: UsageWindowLength, model: String? = nil) {
    self.accountID = accountID
    self.length = length
    self.model = model
  }

  /// Nil for the empty string, which is how "nothing starred" is stored, and for
  /// anything that no longer decodes — a star lost is a glyph without a figure, not
  /// an error.
  init?(stored: String) {
    guard let data = stored.data(using: .utf8),
      let record = try? JSONDecoder().decode(Record.self, from: data)
    else { return nil }
    let length: UsageWindowLength
    switch record.window {
    case "5h": length = .fiveHour
    case "7d": length = .sevenDay
    default: return nil
    }
    self.init(accountID: record.account, length: length, model: record.model)
  }

  var stored: String {
    let record = Record(
      account: accountID, window: length == .fiveHour ? "5h" : "7d", model: model)
    return (try? JSONEncoder().encode(record)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
  }

  private struct Record: Codable {
    let account: String
    let window: String
    let model: String?
  }

  /// "weekly limit", "Fable weekly limit" — for VoiceOver, which cannot see the star.
  var spokenName: String {
    let window = length == .fiveHour ? "session limit" : "weekly limit"
    return model.map { "\($0) \(window)" } ?? window
  }

  /// The window this names, read the way the panes read it.
  ///
  /// **The same corrections, or the menu bar and the pane disagree.** An account-wide
  /// Claude window goes through `UsageSnapshot.window(_:correctedBy:now:)`, so a
  /// refusal newer than the cache reads 100% here too, and falls back to the `limits`
  /// entry the way `AccountUsageCard` does when the flat key is missing. A per-model
  /// window is never corrected, for the reason that card gives.
  @MainActor
  func window(accounts: Accounts, codex: CodexAccounts, now: Date) -> UsageWindow? {
    if let account = accounts.account(id: accountID) {
      guard let usage = account.usage else { return nil }
      let entry = usage.limits.first { $0.scopeModelName == model && $0.length == length }
      guard model == nil else { return entry?.window }
      return usage.window(length, correctedBy: account.quotaHit, now: now) ?? entry?.window
    }
    return codex.account(id: accountID)?.usage?.window(length)
  }

  /// The figure as the menu bar draws it: the percentage, or the em dash
  /// `UsageFigure` shows once the window it belonged to has gone.
  static func figure(_ window: UsageWindow, now: Date) -> String {
    window.hasRolled(asOf: now) ? "—" : "\(window.utilization)%"
  }
}

/// The star beside a meter's title that puts its figure in the menu bar.
///
/// **Hidden until the row is hovered, unless it is the starred one.** Every meter in
/// the app would otherwise carry an outline star that is almost never pressed, which
/// is a column of chrome down the Usage pane. Hidden by painting the glyph clear
/// rather than removing it, so the title does not shift sideways as the pointer
/// crosses the row.
///
/// **Clear, not `opacity(0)`.** SwiftUI drops a fully transparent view from the
/// accessibility tree, which was measured here: with the opacity version, none of the
/// Usage pane's stars existed to VoiceOver or to an accessibility client, beside rows
/// whose every label was present. A clear glyph inside an opaque button keeps the
/// button there for anyone not using a pointer.
struct MenuBarStar: View {
  let limit: MenuBarLimit
  let rowHovered: Bool

  @AppStorage(MenuBarLimit.defaultsKey) private var stored = ""

  var body: some View {
    let isStarred = MenuBarLimit(stored: stored) == limit
    Button {
      // Starring another replaces this one; pressing the filled star clears it.
      stored = isStarred ? "" : limit.stored
    } label: {
      Image(systemName: isStarred ? "star.fill" : "star")
        .imageScale(.small)
        .foregroundStyle(style(isStarred: isStarred))
    }
    .buttonStyle(.borderless)
    .help(isStarred ? "Remove from the menu bar" : "Show beside the menu bar icon")
    .accessibilityLabel(
      isStarred
        ? "Remove the \(limit.spokenName) from the menu bar"
        : "Show the \(limit.spokenName) in the menu bar")
  }

  /// Yellow once starred, the colour a favourite is everywhere else on the Mac, so the
  /// one limit that is in the menu bar can be picked out of a pane of grey meters.
  private func style(isStarred: Bool) -> AnyShapeStyle {
    if isStarred { return AnyShapeStyle(.yellow) }
    return rowHovered ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.clear)
  }
}
