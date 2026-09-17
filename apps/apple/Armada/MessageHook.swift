import Foundation

/// The Stop hook that delivers an agent's message to a Claude Code session, and the edit that puts
/// it in an account's `settings.json` or takes it out.
///
/// **How a message arrives.** When a turn ends, Claude Code starts the hook in the background
/// (`asyncRewake`). The script finds the session's id in the hook's input and waits on that
/// session's inbox in Armada's own folder. When `SessionInbox` writes a message there, the script
/// prints it and exits 2, and Claude Code wakes the session with it. Measured on 2.1.273,
/// 2026-09-16: the hook starts 0.5s after the turn ends, a message written to an idle session was
/// answered 2.7s later, and the hook was waiting again 0.5s after that turn. See
/// docs/reaching-agents.md.
///
/// **What the script guards against, each measured the same day:**
/// - *Piling up.* A hook that got no message keeps running when the person prompts normally, and
///   the next turn's end starts another. Each run writes its pid to `listening` and exits once a
///   newer run has overwritten it.
/// - *Outliving the session.* Claude Code signals a pending hook when it quits; the script also
///   stops when its parent, the session's `claude`, is gone, for a session that was killed.
/// - *Stale instructions.* A message older than `expiryMinutes` is deleted unread.
/// - *Two runs taking one message.* A message is claimed by `mv` before it is printed.
/// - *Grok Build running it.* Grok reads `~/.claude/settings.json` hooks, knows no `asyncRewake`,
///   and sends `session_id` beside its own camelCase keys, so the script would hold every Grok turn
///   open for the whole timeout. Measured on grok 1.0.34, 2026-09-17: a one-word turn hung until
///   killed. The script leaves at once when `GROK_HOOK_EVENT` is set or the input has
///   `hookEventName`, which Claude Code never sends. See docs/grok-sessions.md.
/// - *Armada deleted with the hook still installed.* The command runs the script only when it is
///   there, and otherwise exits 0, which Claude Code ignores.
///
/// **An edit of the bytes, never a rewrite**, for `ClaudeTrust`'s reasons, with its scanner and
/// its check: the result is parsed and compared with the original plus or minus the entry, and
/// anything but equal writes nothing.
nonisolated enum MessageHook {
  /// Long, because an idle session is reachable only while its hook runs. Accepted as given on
  /// 2.1.273; the default for a command hook is 600s.
  static let timeoutSeconds = 86_400
  static let expiryMinutes = 60
  static let scriptName = "deliver-message.zsh"

  /// The hook command as `settings.json` holds it. Both paths are single-quoted shell words.
  static func command(script: String, inbox: String) -> String {
    let quotedScript = LaunchScript.quoted(script)
    return
      "f=\(quotedScript); [ -f \"$f\" ] && exec /bin/zsh \"$f\" \(LaunchScript.quoted(inbox)); exit 0"
  }

  /// The script, byte for byte. Takes the inbox root as its one argument.
  static let script = """
    #!/bin/zsh
    # Armada: delivers a message a supervisor agent sent to this Claude Code session.
    # Installed as an asyncRewake Stop hook by Armada's Settings > Supervisor > Deliver messages,
    # and removed by turning that off. It reads only files Armada wrote for this session and
    # prints them; it runs nothing it reads.
    emulate -L zsh
    setopt null_glob
    zmodload zsh/zselect 2>/dev/null

    root=$1
    [[ -n $root && -d $root ]] || exit 0
    [[ -n $GROK_HOOK_EVENT ]] && exit 0
    input=$(cat)
    [[ $input == *'"hookEventName"'* ]] && exit 0
    [[ $input =~ '"session_id"[[:space:]]*:[[:space:]]*"([0-9A-Fa-f-]{36})"' ]] || exit 0
    session=${match[1]:l}
    inbox=$root/$session
    mkdir -p -m 700 -- $inbox 2>/dev/null || exit 0
    parent=$PPID
    print -r -- $$ >| $inbox/listening || exit 0

    while true; do
      [[ $(<$inbox/listening) == $$ ]] 2>/dev/null || exit 0
      kill -0 $parent 2>/dev/null || { rm -f -- $inbox/listening; exit 0 }
      rm -f -- $inbox/*.msg(.mm+\(expiryMinutes))
      claimed=()
      for message in $inbox/*.msg(.on); do
        mv -- $message $message.$$ 2>/dev/null && claimed+=($message.$$)
      done
      if (( ${#claimed} )); then
        for message in $claimed; do
          cat -- $message >&2
          print -u2 ''
          rm -f -- $message
        done
        [[ $(<$inbox/listening) == $$ ]] 2>/dev/null && rm -f -- $inbox/listening
        exit 2
      fi
      zselect -t 50 2>/dev/null || sleep 0.5
    done

    """

  enum Edit: Equatable, Sendable {
    case unchanged
    case edited(Data)
    case refused(String)
  }

  /// `settings` with Armada's entry first in `hooks.Stop`, replacing any earlier one of Armada's
  /// for the same script. Nil `settings` is a file that does not exist yet.
  static func installing(_ settings: Data?, command: String, script: String) -> Edit {
    let original = settings ?? Data("{}".utf8)
    let withoutOurs: [UInt8]
    switch removingAll([UInt8](original), script: script) {
    case .failure(let refusal): return .refused(refusal.reason)
    case .success(let bytes): withoutOurs = bytes
    }

    let scanner = JSONScanner(bytes: withoutOurs)
    guard let root = scanner.object(at: scanner.skipSpace(from: 0)) else {
      return .refused("the settings are not a JSON object")
    }
    let group = "{\"hooks\": [\(entry(command))]}"
    let insertion: (at: Int, text: String)
    if let hooks = root.last(named: "hooks", in: withoutOurs) {
      guard let events = scanner.object(at: hooks.value.lowerBound) else {
        return .refused("hooks is not an object")
      }
      if let stop = events.last(named: "Stop", in: withoutOurs) {
        guard let groups = scanner.array(at: stop.value.lowerBound) else {
          return .refused("hooks.Stop is not an array")
        }
        insertion = first(group, in: groups.start, before: groups.elements.first, withoutOurs)
      } else {
        let text = "\"Stop\": [\(group)]"
        insertion = first(text, in: events.start, before: events.members.first?.range, withoutOurs)
      }
    } else {
      let text = "\"hooks\": {\"Stop\": [\(group)]}"
      insertion = first(text, in: root.start, before: root.members.first?.range, withoutOurs)
    }

    var edited = withoutOurs
    edited.insert(contentsOf: Array(insertion.text.utf8), at: insertion.at)
    let data = Data(edited)
    guard let expected = expectedSettings(original, script: script, adding: command),
      let actual = try? JSONSerialization.jsonObject(with: data) as? NSDictionary,
      expected.isEqual(actual)
    else {
      return .refused("the edited settings did not compare equal to the original plus the hook")
    }
    if settings != nil,
      let before = try? JSONSerialization.jsonObject(with: original) as? NSDictionary,
      before.isEqual(actual)
    {
      return .unchanged
    }
    return .edited(data)
  }

  /// `settings` with every entry of Armada's for `script` taken out, and a `Stop` list or `hooks`
  /// object that only Armada's entry was holding taken out with it.
  static func removing(_ settings: Data, script: String) -> Edit {
    switch removingAll([UInt8](settings), script: script) {
    case .failure(let refusal):
      return .refused(refusal.reason)
    case .success(let bytes):
      let data = Data(bytes)
      guard data != settings else { return .unchanged }
      guard let expected = expectedSettings(settings, script: script, adding: nil),
        let actual = try? JSONSerialization.jsonObject(with: data) as? NSDictionary,
        expected.isEqual(actual)
      else {
        return .refused("the edited settings did not compare equal to the original minus the hook")
      }
      return .edited(data)
    }
  }

  /// Whether `settings` holds exactly `command` as a Stop hook.
  static func isInstalled(_ settings: Data, command: String) -> Bool {
    guard let root = try? JSONSerialization.jsonObject(with: settings) as? [String: Any],
      let hooks = root["hooks"] as? [String: Any],
      let groups = hooks["Stop"] as? [[String: Any]]
    else { return false }
    return groups.contains { group in
      (group["hooks"] as? [[String: Any]])?.contains { $0["command"] as? String == command }
        ?? false
    }
  }

  // MARK: - The edit

  /// Where a new first element goes, and its text: directly inside the bracket when the list is
  /// empty, else in front of the current first one, followed by a comma and the same whitespace
  /// that stood before it, so a file laid out one member per line stays that way.
  private static func first(
    _ text: String, in open: Int, before current: Range<Int>?, _ bytes: [UInt8]
  ) -> (Int, String) {
    guard let current else { return (open + 1, text) }
    let gap = String(decoding: bytes[(open + 1)..<current.lowerBound], as: UTF8.self)
    return (current.lowerBound, text + "," + (gap.isEmpty ? " " : gap))
  }

  private static func entry(_ command: String) -> String {
    "{\"type\": \"command\", \"command\": \(quotedJSON(command)), \"asyncRewake\": true, "
      + "\"timeout\": \(timeoutSeconds)}"
  }

  private static func quotedJSON(_ string: String) -> String {
    let data = try? JSONSerialization.data(
      withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
  }

  /// A hook of Armada's is one whose command names this build's script.
  private static func isOurs(_ command: Any?, script: String) -> Bool {
    (command as? String)?.contains(script) ?? false
  }

  /// Remove Armada's entries one at a time until there are none, rescanning after each so every
  /// byte range is current.
  private static func removingAll(_ start: [UInt8], script: String) -> Result<[UInt8], Refusal> {
    var bytes = start
    for _ in 0..<32 {
      let scanner = JSONScanner(bytes: bytes)
      guard let root = scanner.object(at: scanner.skipSpace(from: 0)),
        scanner.skipSpace(from: root.end) == bytes.count
      else { return .failure(Refusal("the settings are not a single JSON object")) }
      guard let hooksMember = root.last(named: "hooks", in: bytes) else { return .success(bytes) }
      guard let events = scanner.object(at: hooksMember.value.lowerBound) else {
        return .success(bytes)
      }
      guard let stopMember = events.last(named: "Stop", in: bytes),
        let groups = scanner.array(at: stopMember.value.lowerBound)
      else { return .success(bytes) }

      var cut: Range<Int>?
      search: for (groupIndex, groupRange) in groups.elements.enumerated() {
        guard let group = scanner.object(at: groupRange.lowerBound),
          let handlersMember = group.last(named: "hooks", in: bytes),
          let handlers = scanner.array(at: handlersMember.value.lowerBound)
        else { continue }
        for (handlerIndex, handlerRange) in handlers.elements.enumerated() {
          guard let handler = scanner.object(at: handlerRange.lowerBound),
            let commandMember = handler.last(named: "command", in: bytes),
            isOurs(
              try? JSONSerialization.jsonObject(
                with: Data(bytes[commandMember.value]), options: .fragmentsAllowed),
              script: script)
          else { continue }
          // The outermost thing that holds nothing but this handler goes.
          if handlers.elements.count > 1 {
            cut = listCut(handlers.elements, handlerIndex)
          } else if groups.elements.count > 1 {
            cut = listCut(groups.elements, groupIndex)
          } else if events.members.count > 1 {
            cut = listCut(
              events.members.map(\.range), events.members.firstIndex { $0.key == stopMember.key }!)
          } else {
            cut = listCut(
              root.members.map(\.range), root.members.firstIndex { $0.key == hooksMember.key }!)
          }
          break search
        }
      }
      guard let cut else { return .success(bytes) }
      bytes.removeSubrange(cut)
    }
    return .failure(Refusal("the settings hold more copies of Armada's hook than expected"))
  }

  /// The bytes to delete to take element `index` out of a comma-separated list, with one comma.
  private static func listCut(_ elements: [Range<Int>], _ index: Int) -> Range<Int> {
    if index + 1 < elements.count {
      return elements[index].lowerBound..<elements[index + 1].lowerBound
    }
    if index > 0 {
      return elements[index - 1].upperBound..<elements[index].upperBound
    }
    return elements[index]
  }

  /// The settings as they should parse after the edit, built from the parsed original.
  private static func expectedSettings(_ original: Data, script: String, adding command: String?)
    -> NSDictionary?
  {
    guard
      let root = try? JSONSerialization.jsonObject(with: original, options: .mutableContainers)
        as? NSMutableDictionary
    else { return nil }
    if let hooks = root["hooks"] as? NSMutableDictionary,
      let groups = hooks["Stop"] as? NSMutableArray
    {
      var emptied = false
      for group in groups.reversed() {
        guard let group = group as? NSMutableDictionary,
          let handlers = group["hooks"] as? NSMutableArray
        else { continue }
        let before = handlers.count
        handlers.filter(
          using: NSPredicate { handler, _ in
            !isOurs((handler as? NSDictionary)?["command"], script: script)
          })
        if handlers.count < before, handlers.count == 0 {
          groups.remove(group)
          emptied = true
        }
      }
      if emptied, groups.count == 0 {
        hooks.removeObject(forKey: "Stop")
        if hooks.count == 0 { root.removeObject(forKey: "hooks") }
      }
    }
    if let command {
      let group: NSDictionary = [
        "hooks": [
          [
            "type": "command", "command": command, "asyncRewake": true,
            "timeout": timeoutSeconds,
          ]
        ]
      ]
      let hooks = root["hooks"] as? NSMutableDictionary ?? NSMutableDictionary()
      let groups = hooks["Stop"] as? NSMutableArray ?? NSMutableArray()
      groups.insert(group, at: 0)
      hooks["Stop"] = groups
      root["hooks"] = hooks
    }
    return root
  }

  struct Refusal: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
  }
}

extension MessageHook.Refusal: CustomStringConvertible {
  var description: String { reason }
}

nonisolated extension JSONScanner {
  struct List {
    /// The `[`.
    let start: Int
    /// Just past the `]`.
    let end: Int
    let elements: [Range<Int>]
  }

  /// The array starting at `index`, or nil when there is not one there.
  func array(at index: Int) -> List? {
    guard index < bytes.count, bytes[index] == UInt8(ascii: "[") else { return nil }
    var elements: [Range<Int>] = []
    var cursor = skipSpace(from: index + 1)
    if cursor < bytes.count, bytes[cursor] == UInt8(ascii: "]") {
      return List(start: index, end: cursor + 1, elements: [])
    }
    while cursor < bytes.count {
      guard let end = valueEnd(at: cursor) else { return nil }
      elements.append(cursor..<end)
      cursor = skipSpace(from: end)
      guard cursor < bytes.count else { return nil }
      if bytes[cursor] == UInt8(ascii: "]") {
        return List(start: index, end: cursor + 1, elements: elements)
      }
      guard bytes[cursor] == UInt8(ascii: ",") else { return nil }
      cursor = skipSpace(from: cursor + 1)
    }
    return nil
  }
}

nonisolated extension JSONScanner.Member {
  /// The whole member, key to value.
  var range: Range<Int> { key.lowerBound..<value.upperBound }
}
