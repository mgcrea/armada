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
  /// What a session started in this project loads today, or nil until the probe
  /// answers. Claude-only: see `ContextProbe`.
  let composition: ContextComposition?
  let now: Date

  var body: some View {
    if let context = session.context {
      let window = ContextWindow.resolve(
        sessionModelID: session.sessionModelID,
        accountModelID: accountModelID,
        messageModelID: context.modelID,
        observedTotal: context.total)
      let categories = categories(context: context)

      ContextPanel(
        // The resolved id, not `message.model`: the variant suffix is the whole
        // difference between a 200k window and a 1M one, and a transcript never
        // carries it. `/context` shows the same string.
        modelLabel: window.displayModelID ?? context.modelID ?? "Unknown model",
        categories: categories,
        limit: window.limit,
        limitHelp: window.source.explanation,
        growth: session.growth,
        compaction: session.compaction,
        cache: session.promptCache,
        composition: composition,
        now: now)
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

/// The context panel itself: headline, bar, table, and whatever the vendor can add
/// underneath.
///
/// **Takes figures, not a session, and that is what keeps the two vendors in step.**
/// Claude and Codex arrive at these numbers by completely different routes — one sums
/// three fields of an assistant turn's `usage` and infers the window size from a model
/// id, the other reads `last_token_usage` and a stated `model_context_window` out of a
/// `token_count` event — but what a reader wants to see is identical, so the rendering
/// is written once and each vendor supplies the data. `ContextSection` and
/// `CodexContextSection` are the two adapters, and each is short enough to read in one
/// go.
///
/// `compaction` is nil for Codex: nothing in a rollout records one, and no session on
/// this Mac has ever contained the word outside its system prompt.
struct ContextPanel: View {
  let modelLabel: String
  let categories: [ContextCategory]
  let limit: Int
  /// Where `limit` came from, as a tooltip. The two vendors differ most here: Codex
  /// states the number, Claude's has to be resolved from whatever is available.
  let limitHelp: String
  var growth: ContextGrowth?
  var compaction: Compaction?
  /// Nil for Codex and Grok, whose logs never say how long their caches live, and for
  /// a Claude session that is mid-turn. See `Session.promptCache`.
  var cache: PromptCache?
  /// The probed breakdown of what a fresh session here would load. Nil for Codex,
  /// which has no equivalent, and nil until the probe answers.
  var composition: ContextComposition?
  let now: Date

  var body: some View {
    let used = categories.reduce(0) { $0 + $1.tokens }
    Section("Context") {
      VStack(alignment: .leading, spacing: 6) {
        Text(modelLabel)
          .font(.callout)
          .foregroundStyle(.secondary)
        Text(TokenCount.headline(total: used, limit: limit))
          .font(.callout.monospacedDigit())
          .contentTransition(.numericText())
        ContextBar(categories: categories, limit: limit)
          .padding(.top, 2)
      }
      .padding(.vertical, 2)
      .help(limitHelp)

      CategoryHeader()
      ForEach(categories) { category in
        CategoryRow(
          name: category.name, tokens: category.tokens, limit: limit, color: category.color
        )
        .help(category.help)
      }
      // No swatch: free space is the track, not a band on it.
      CategoryRow(name: "Free space", tokens: max(limit - used, 0), limit: limit, color: nil)

      if let growth {
        GrowthLine(growth: growth, total: used, limit: limit, now: now)
      }
      if let compaction {
        CompactionLine(compaction: compaction, now: now)
      }
      if let cache {
        PromptCacheLine(cache: cache, now: now)
      }
      if let composition {
        CompositionGroup(composition: composition, limit: limit)
      }
    }
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

/// Whether the prompt cache is still warm, and what going cold costs.
///
/// Prefixed with `~` like `GrowthLine`: the expiry is an upper bound, measured from
/// when the newest response was written. See `PromptCache`.
private struct PromptCacheLine: View {
  let cache: PromptCache
  let now: Date

  var body: some View {
    let warm = cache.isWarm(at: now)
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 4) {
        Image(systemName: warm ? "timer" : "snowflake")
          .imageScale(.small)
        if warm {
          Text("Cache warm, expires ~\(cache.expiresAt, format: .relative(presentation: .named))")
        } else {
          Text("Cache expired ~\(cache.expiresAt, format: .relative(presentation: .named))")
        }
      }
      .font(.caption2)
      .foregroundStyle(
        cache.isExpiringSoon(at: now) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))

      if !warm {
        Text("Next turn re-caches \(TokenCount.short(cache.tokens))")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
      }
    }
    .help(
      "This session writes to the \(cache.ttl == .oneHour ? "1-hour" : "5-minute") prompt "
        + "cache, and every request resets its clock. While it is warm the next turn reads "
        + "the prompt at a tenth of the input price; once it lapses, the whole prompt is "
        + "written back at \(cache.ttl == .oneHour ? "twice" : "1.25×") the input price. "
        + "Anthropic can evict sooner, so the time is an upper bound.")
  }
}

/// The breakdown `/context` shows, for a session started in this project now.
///
/// **Its own group with its own total, never merged into the table above.** The rows
/// above are this session's, read from its transcript; these come from a probe of a
/// *fresh* session in the same directory, and the two totals will not match — they
/// differ by the first prompt, by anything loaded part-way through, and by whatever
/// has changed in the config since. Presenting them as one table would invite
/// subtracting one from the other, which is the one thing these numbers cannot do.
private struct CompositionGroup: View {
  let composition: ContextComposition
  let limit: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("A session started here loads")
        .font(.caption2.weight(.semibold))
        .textCase(.uppercase)
        .foregroundStyle(.tertiary)
      Text(
        "Measured by asking Claude Code, not this session — it cannot report another "
          + "process's context. The total below is its own."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.top, 2)
    .help("Measured \(composition.measuredAt.formatted(date: .omitted, time: .shortened)).")

    ForEach(composition.categories) { category in
      CategoryRow(
        name: category.name, tokens: category.tokens, limit: limit,
        color: ContextCategory.color(forProbed: category.name))
    }
    CategoryRow(name: "Total", tokens: composition.total, limit: limit, color: nil)

    // The files by name, which is the part `/context` shows only as one number and
    // the part someone can act on: a 20k CLAUDE.md is a thing to go and edit.
    ForEach(composition.memoryFiles) { file in
      HStack(spacing: 8) {
        Text(file.displayPath)
          .truncationMode(.head)
        Spacer(minLength: 8)
        Text(TokenCount.short(file.tokens))
          .monospacedDigit()
      }
      .font(.caption2)
      .foregroundStyle(.tertiary)
      .lineLimit(1)
      .help(file.path)
    }
  }
}
