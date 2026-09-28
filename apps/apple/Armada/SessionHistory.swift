import Foundation

/// Which Claude Code sessions an account's History lists, and how the list is cut into days.
///
/// **Everything with no process behind it.** A session that ended, one closed from Armada, and a
/// VS Code tab restored after a reload with nothing running until someone types in it all look
/// the same from here: a transcript and no registry file. The last kind is the one that goes
/// missing, since it looks open in the editor and is absent from the live list.
///
/// **From the usage ledger, as `RecentSessions` is.** The indexer already keeps a row per
/// session with the folder it ran in and when it last wrote, so the history is a filter over a
/// value already in memory. What it is not is small: 1,461 sessions on one account on this Mac on
/// 2026-09-28, 47 of them from the last day. Hence days and a search, where "Recently ended"
/// gets away with eight rows.
///
/// **`account: nil` is every account**, which is what a History pane of its own would list.
nonisolated enum SessionHistory {
  /// - Parameter live: ids Armada is watching now. They are in the live list, and resuming one
  ///   would put two writers on its transcript.
  static func pick(
    from sessions: [UsageSessionRow], account: String?, live: Set<String>
  ) -> [UsageSessionRow] {
    // The ledger's key is (account, vendor, id), so a conversation continued on another account
    // can have a row on each. Listed once, on the account that wrote it last: that is where
    // it went on, and the other is the copy it was continued from.
    var seen: Set<String> = []
    return
      sessions
      .filter { $0.vendor == .claude && !$0.isChild && !live.contains($0.sessionID) }
      .filter { account == nil || $0.account == account }
      .sorted {
        if $0.lastAt != $1.lastAt { return $0.lastAt > $1.lastAt }
        if $0.sessionID != $1.sessionID { return $0.sessionID < $1.sessionID }
        return $0.account < $1.account
      }
      .filter { seen.insert($0.sessionID).inserted }
  }

  /// One day of the list, the rows last written on it.
  struct Day: Identifiable, Sendable {
    /// The day's first instant in the calendar it was cut with.
    let id: Date
    let title: String
    let rows: [UsageSessionRow]
  }

  /// `rows`, newest first as `pick` returns them, cut at each local midnight.
  static func days(
    _ rows: [UsageSessionRow], now: Date, calendar: Calendar = .current, locale: Locale = .current
  ) -> [Day] {
    var days: [Day] = []
    var current: (start: Date, rows: [UsageSessionRow])?
    for row in rows {
      let start = calendar.startOfDay(for: row.lastAt)
      if let open = current, open.start == start {
        current?.rows.append(row)
        continue
      }
      if let open = current {
        days.append(
          Day(
            id: open.start,
            title: dayTitle(for: open.start, now: now, calendar: calendar, locale: locale),
            rows: open.rows))
      }
      current = (start, [row])
    }
    if let open = current {
      days.append(
        Day(
          id: open.start,
          title: dayTitle(for: open.start, now: now, calendar: calendar, locale: locale),
          rows: open.rows))
    }
    return days
  }

  /// "Today", "Yesterday", a weekday for the rest of the last week, then a date, with its year
  /// only when it is not this one.
  ///
  /// **A weekday for six days back, not seven.** Seven days ago shares its weekday with today,
  /// and a "Monday" section below "Today" on a Monday reads as a mistake.
  static func dayTitle(
    for date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current
  ) -> String {
    let day = calendar.startOfDay(for: date)
    let today = calendar.startOfDay(for: now)
    let back = calendar.dateComponents([.day], from: day, to: today).day ?? 0
    var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    switch back {
    case ...0: return "Today"
    case 1: return "Yesterday"
    case 2...6: return date.formatted(style.weekday(.wide))
    default:
      style = style.month(.abbreviated).day()
      if calendar.component(.year, from: day) != calendar.component(.year, from: today) {
        style = style.year()
      }
      return date.formatted(style)
    }
  }

  /// Whether a row answers a search: every word in the title or in the folder, ignoring case
  /// and accents.
  ///
  /// **Only the title the list has read.** Titles are read from each transcript's tail after
  /// the rows are listed, so a search typed in the first second of opening History can miss a
  /// row it will match a moment later. What is inside a transcript is not searched.
  static func matches(_ query: String, title: String?, cwd: String) -> Bool {
    let words = query.split(whereSeparator: \.isWhitespace)
    guard !words.isEmpty else { return true }
    let haystacks = [title, cwd].compactMap { $0 }
    return words.allSatisfy { word in
      haystacks.contains {
        $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
      }
    }
  }

  /// "1,461 sessions", or "12 of 1,461 sessions" while a search is narrowing it.
  static func countLabel(shown: Int, total: Int, locale: Locale = .current) -> String {
    let noun = total == 1 ? "session" : "sessions"
    let all = total.formatted(.number.locale(locale))
    guard shown != total else { return "\(all) \(noun)" }
    return "\(shown.formatted(.number.locale(locale))) of \(all) \(noun)"
  }
}
