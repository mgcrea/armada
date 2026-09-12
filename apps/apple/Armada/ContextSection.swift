import SwiftUI

/// What a session is carrying, laid out like Claude Code's own `/context`.
///
/// **Every figure here is a number Claude Code recorded, not one Armada estimated.**
/// That constraint is what shapes the panel. `/context` names seven categories; the
/// five that make up the fixed prefix are computed in the running process and never
/// written to disk, so they arrive here as one measured total and the panel says so
/// rather than leaving the difference to be discovered. See `TranscriptContext`.
struct ContextSection: View {
  let session: Session
  let accountModelID: String?
  let now: Date

  var body: some View {
    if let context = session.context {
      let window = ContextWindow.resolve(
        sessionModelID: session.sessionModelID,
        accountModelID: accountModelID,
        messageModelID: context.modelID,
        observedTotal: context.total)
      let categories = categories(context: context)
      let used = categories.reduce(0) { $0 + $1.tokens }

      Section("Context") {
        VStack(alignment: .leading, spacing: 6) {
          // The resolved id, not `message.model`: the variant suffix is the whole
          // difference between a 200k window and a 1M one, and a transcript never
          // carries it. `/context` shows the same string.
          Text(window.displayModelID ?? context.modelID ?? "Unknown model")
            .font(.callout)
            .foregroundStyle(.secondary)
          Text(TokenCount.headline(total: used, limit: window.limit))
            .font(.callout.monospacedDigit())
            .contentTransition(.numericText())
          ContextBar(categories: categories, limit: window.limit)
            .padding(.top, 2)
        }
        .padding(.vertical, 2)
        .help(window.source.explanation)

        CategoryHeader()
        ForEach(categories) { category in
          CategoryRow(
            name: category.name, tokens: category.tokens, limit: window.limit,
            color: category.color
          )
          .help(category.help)
        }
        // No swatch: free space is the track, not a band on it.
        CategoryRow(
          name: "Free space", tokens: max(window.limit - used, 0), limit: window.limit,
          color: nil)

        if let growth = session.growth {
          GrowthLine(growth: growth, total: used, limit: window.limit, now: now)
        }
        if let compaction = session.compaction {
          CompactionLine(compaction: compaction, now: now)
        }
      }
    }
  }

  /// The bands, which partition the context and sum to `used`.
  ///
  /// Two, where `/context` has six, and the split is the one the transcript actually
  /// supports: what was loaded before the first prompt, and everything since.
  ///
  /// **"Conversation" rather than "Added since", and that is not cosmetic.** After a
  /// compaction the middle of the session has been thrown away, so the figure is no
  /// longer cumulative growth — but it is still, accurately, everything in the
  /// context that is not the opening prefix. The neutral name is true in both cases,
  /// which is why this no longer disappears once a session has compacted.
  private func categories(context: ContextReading) -> [ContextCategory] {
    guard let baseline = session.baseline?.loadedAtStart, baseline <= context.total else {
      return [
        ContextCategory(
          name: "Context used", tokens: context.total,
          color: ContextCategory.conversationColor,
          help: "The whole prompt on the newest turn. The opening figure has not been read "
            + "yet, so it is not split here.")
      ]
    }
    return [
      ContextCategory(
        name: "Loaded at start", tokens: baseline, color: ContextCategory.prefixColor,
        help: "The system prompt, tools, memory files and skills, as one figure. Claude Code "
          + "splits these in /context, but it works them out as it runs and never writes the "
          + "parts down."),
      ContextCategory(
        name: "Conversation", tokens: context.total - baseline,
        color: ContextCategory.conversationColor,
        help: "Everything in the context beyond the opening prefix — the turns themselves, "
          + "plus anything loaded part-way through the session."),
    ]
    // Empty bands are dropped, as `/context` drops its own: a session whose only
    // request is still its first has a "Conversation" of exactly 0, and a row reading
    // `0  0.0%` is noise that looks like a defect.
    .filter { $0.tokens > 0 }
  }
}

/// `CATEGORY … TOKENS  USAGE`, the column heads from `/context`.
private struct CategoryHeader: View {
  var body: some View {
    HStack(spacing: 8) {
      Text("Category")
      Spacer(minLength: 8)
      Text("Tokens").frame(width: 60, alignment: .trailing)
      Text("Usage").frame(width: 52, alignment: .trailing)
    }
    .font(.caption2.weight(.semibold))
    .textCase(.uppercase)
    .foregroundStyle(.tertiary)
  }
}

/// One banded row: swatch, name, tokens, share of the window.
private struct CategoryRow: View {
  let name: String
  let tokens: Int
  let limit: Int
  /// Nil for free space, which has no band in the bar to point at.
  let color: Color?

  var body: some View {
    HStack(spacing: 8) {
      // The swatch keeps its slot when there is no colour, so the names stay in one
      // column and "Free space" does not shuffle left out of the list.
      RoundedRectangle(cornerRadius: 2)
        .fill(color ?? .clear)
        .frame(width: 10, height: 10)
      Text(name)
        .foregroundStyle(color == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
      Spacer(minLength: 8)
      Text(TokenCount.short(tokens))
        .frame(width: 60, alignment: .trailing)
        .monospacedDigit()
      Text(TokenCount.share(tokens, of: limit))
        .frame(width: 52, alignment: .trailing)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
    .font(.callout)
    .lineLimit(1)
  }
}

/// How fast the window is filling, and when it runs out.
///
/// Prefixed with `~` and carrying a `.help()` naming the assumption, matching how
/// `UsageVerdictLine` labels every projected figure in the usage panes.
private struct GrowthLine: View {
  let growth: ContextGrowth
  let total: Int
  let limit: Int
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text("+\(TokenCount.short(growth.tokensPerRequest)) per request")
        .font(.caption2)
        .foregroundStyle(.secondary)
      if let full = growth.projectedFull(from: total, limit: limit, now: now) {
        Text("~full \(full, format: .relative(presentation: .named))")
          .font(.caption2)
          .foregroundStyle(.orange)
      }
    }
    .help(
      "Projected from the last \(growth.requests) API requests in this session. One prompt "
        + "spans several requests, so this is a rate per request, not per turn.")
  }
}

/// That the session has been compacted, and what it cost.
///
/// Worth its own line because it reframes every figure above it: a session at 9% that
/// has already been compacted has lost history, and the bar no longer describes
/// everything it once knew.
private struct CompactionLine: View {
  let compaction: Compaction
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 4) {
        Image(systemName: "arrow.down.right.and.arrow.up.left")
          .imageScale(.small)
        if let at = compaction.at {
          Text("Compacted \(at, format: .relative(presentation: .named))")
        } else {
          Text("Compacted")
        }
      }
      .font(.caption2)
      .foregroundStyle(.secondary)

      // `postTokens` is optional in the record, so the "from → to" form is
      // conditional and a bare "from" is a real case rather than a fallback.
      if let pre = compaction.preTokens {
        Text(
          compaction.postTokens.map { "\(TokenCount.short(pre)) → \(TokenCount.short($0))" }
            ?? "from \(TokenCount.short(pre))"
        )
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.tertiary)
      }
    }
    .help(
      compaction.wasManual
        ? "This session was compacted with /compact."
        : "Claude Code compacted this session automatically when it filled its window.")
  }
}
