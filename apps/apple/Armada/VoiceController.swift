import AppKit
import ArmadaMCP
import ArmadaSupervisor
import Foundation
import Observation

/// Talk to Armada: a global shortcut, a spoken question, a spoken answer.
///
/// The one coordinator. `VoiceTurn` decides what every press, pause, reply line and failure
/// means; this performs its effects against the microphone (`VoiceCapture`), the `claude` that
/// answers (`SupervisorProcess`), the synthesizer (`Speaker`) and the card (`VoiceOverlay`),
/// and holds the text the card shows.
///
/// **Voice reads the fleet the way the Terminal supervisor does**, through the MCP server in
/// Settings ▸ Supervisor, so it needs that server running. It never starts it: turning on a
/// listening socket stays a switch the person flips.
@MainActor @Observable
final class VoiceController {
  enum Problem: LocalizedError {
    case serverOff
    case noToken(String?)
    case noAccount
    case noClaude

    var errorDescription: String? {
      switch self {
      case .serverOff: "Turn on the MCP server in Settings ▸ Supervisor first."
      case .noToken(let reason):
        "Armada could not read the MCP server's token" + (reason.map { ": \($0)" } ?? ".")
      case .noAccount: "Armada found no Claude account to answer with."
      case .noClaude: "Armada couldn't find claude. Install Claude Code, then try again."
      }
    }
  }

  static let shared = VoiceController()

  nonisolated static let enabledKey = "armada.voiceEnabled"
  nonisolated static let modeKey = "armada.voiceMode"
  nonisolated static let accountKey = "armada.voiceAccount"
  nonisolated static let speaksKey = "armada.voiceSpeaks"
  nonisolated static let voiceKey = "armada.voiceIdentifier"
  nonisolated static let replyLanguageKey = "armada.voiceReplyLanguage"
  nonisolated static let instructionsKey = "armada.voiceInstructions"
  nonisolated static let followUpKey = "armada.voiceFollowUp"
  /// Where conversation ids were kept before they lived in memory. Removed at launch.
  nonisolated static let legacySessionsKey = "armada.voiceSessions"

  static let dismissDelay: Duration = .seconds(6)
  /// How long after a reply is spoken before the microphone opens for an answer. Untuned.
  static let answerSettle: Duration = .milliseconds(300)

  static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
  static var mode: VoiceMode {
    UserDefaults.standard.string(forKey: modeKey).flatMap(VoiceMode.init(rawValue:)) ?? .press
  }
  static var speaksReplies: Bool {
    UserDefaults.standard.object(forKey: speaksKey) as? Bool ?? true
  }
  static var followUp: VoiceFollowUp {
    UserDefaults.standard.string(forKey: followUpKey).flatMap(VoiceFollowUp.init(rawValue:))
      ?? .afterQuestion
  }
  static var voiceChoice: VoiceChoice {
    VoiceChoice(storageValue: UserDefaults.standard.string(forKey: voiceKey))
  }
  static var replyLanguage: ReplyLanguage {
    ReplyLanguage(storageValue: UserDefaults.standard.string(forKey: replyLanguageKey))
  }
  /// How voice should answer, as written in Settings ▸ Voice. Unset means `VoiceBrief.defaultStyle`.
  static var instructions: String {
    UserDefaults.standard.string(forKey: instructionsKey) ?? VoiceBrief.defaultStyle
  }

  private(set) var turn = VoiceTurn(mode: .press)
  /// The question as it is being heard.
  private(set) var transcript = ""
  /// The question as it was sent.
  private(set) var question = ""
  private(set) var reply = ""
  private(set) var toolLabel: String?
  private(set) var level: Float = -160
  private(set) var preparingSpeech = false
  /// This conversation's questions and replies, as the Voice pane lists them. In memory
  /// only: a new conversation, another account or a relaunch starts the list empty.
  private(set) var exchanges: [VoiceExchange] = []
  /// The conversation `claude` resumes when a new process has to start: after a setting
  /// changed, or after it stopped. In memory only, like `exchanges`, and for the same reason:
  /// measured 2026-09-16, a conversation resumed after a relaunch still held a refusal from
  /// before it, and the voice warned about it from a history the pane no longer showed.
  /// Kept with the config folder it ran on and the brief it began with, so another account never
  /// resumes it and a changed brief starts a new one (see `VoiceConversation`).
  @ObservationIgnored private var conversation: VoiceConversation?

  @ObservationIgnored private let capture = VoiceCapture()
  @ObservationIgnored private let speaker = Speaker()
  @ObservationIgnored private let overlay = VoiceOverlay()
  @ObservationIgnored private var process: SupervisorProcess?
  @ObservationIgnored private var processFolder: String?
  /// The brief the running `claude` was started with. A conversation keeps the brief it began
  /// with, so a different one, from the reply language, the instructions or Allow writes, starts a
  /// new process on a new conversation at the next question.
  @ObservationIgnored private var processBrief: String?
  /// Whether the running `claude` was allowed `armada_start_session`. Also fixed at launch, so
  /// flipping Allow writes takes effect the same way, at the next question.
  @ObservationIgnored private var processCanStartSessions: Bool?
  /// Bumped for every process started or stopped, so a late event or exit from the one before
  /// is recognised and dropped.
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var sawEvent = false
  @ObservationIgnored private var resumed = false
  @ObservationIgnored private var chunker = SentenceChunker()
  @ObservationIgnored private var pendingError: String?
  @ObservationIgnored private var starting: Task<Void, Never>?
  @ObservationIgnored private var dismissal: Task<Void, Never>?
  /// The pointer is on the card, which then waits for it to leave before hiding.
  @ObservationIgnored private var pointerOnCard = false

  private init() {
    UserDefaults.standard.removeObject(forKey: Self.legacySessionsKey)
    capture.onTranscript = { [weak self] in self?.transcript = $0 }
    capture.onLevel = { [weak self] in self?.level = $0 }
    capture.onPause = { [weak self] _ in self?.dispatch(.speechEnded) }
    capture.onPreparing = { [weak self] in self?.preparingSpeech = $0 }
    speaker.onFinished = { [weak self] in self?.dispatch(.speechFinished) }
    VoiceShortcut.shared.onPress = { [weak self] in self?.dispatch(.shortcutDown) }
    VoiceShortcut.shared.onRelease = { [weak self] in self?.dispatch(.shortcutUp) }
    VoiceShortcut.shared.onStop = { [weak self] in self?.dispatch(.stop) }
  }

  // MARK: - Switching on and off

  /// Register the shortcut while voice is on and Armada is entitled, and stand everything
  /// down otherwise. Called by `EntitlementMonitor.apply()` and by Settings ▸ Voice.
  func sync() {
    if Self.isEnabled, EntitlementMonitor.shared.current.isEntitled {
      VoiceShortcut.shared.register(VoiceShortcut.Chord.stored)
      SpeechModelStore.recognizer.warmUp()
      if Self.speaksReplies, case .kokoro = Self.voiceChoice {
        SpeechModelStore.voice.warmUp()
      }
    } else {
      VoiceShortcut.shared.unregister()
      standDown()
      SpeechModelStore.recognizer.release()
      SpeechModelStore.voice.release()
    }
  }

  /// The next question starts a new conversation instead of continuing this one.
  func startNewConversation() {
    conversation = nil
    exchanges = []
    stopProcess()
  }

  /// The account changed: the next question starts that account's own `claude`.
  func accountChanged() {
    conversation = nil
    exchanges = []
    stopProcess()
  }

  private func standDown() {
    starting?.cancel()
    capture.cancel()
    speaker.stop()
    dismissal?.cancel()
    overlay.hide()
    turn = VoiceTurn(mode: Self.mode, speaksReplies: Self.speaksReplies, followUp: Self.followUp)
    VoiceShortcut.shared.setStopKey(false)
    stopProcess()
  }

  // MARK: - What the card shows

  var headline: String {
    switch turn.phase {
    case .idle: ""
    case .listening(let finishing):
      if preparingSpeech {
        "Getting speech recognition ready…"
      } else if !transcript.isEmpty {
        transcript
      } else {
        finishing ? "…" : turn.listensForAnswer ? "Listening for your answer…" : "Listening…"
      }
    case .thinking, .answering: question
    case .failed(let message): message
    }
  }

  var detail: String? {
    switch turn.phase {
    // What you are answering stays on the card while you answer it.
    case .listening(finishing: false) where turn.listensForAnswer && !reply.isEmpty:
      reply
    case .listening(finishing: false):
      turn.mode == .press
        ? "Pause, or press \(VoiceShortcut.Chord.stored.display) again, to send."
        : "Let go to send."
    case .listening(finishing: true): "Sending…"
    case .thinking: toolLabel ?? "Thinking…"
    case .answering: reply.isEmpty ? toolLabel : reply
    case .failed, .idle: nil
    }
  }

  /// The whole reply once it has finished arriving, even while it is still being spoken. Only
  /// then does the card take clicks: to copy this, or to open the Voice pane.
  var finishedReply: String? {
    guard case .answering(replyDone: true, _) = turn.phase else { return nil }
    let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  /// The pointer came onto the card or left it. The card stays up while you read it, and hides
  /// the usual delay after you move away.
  func pointerMoved(onCard: Bool) {
    guard pointerOnCard != onCard, finishedReply != nil || !onCard else { return }
    pointerOnCard = onCard
    if onCard {
      dismissal?.cancel()
    } else if case .answering(replyDone: true, speechDone: true) = turn.phase {
      perform(.scheduleDismiss)
    }
  }

  /// The card's close button.
  func closeCard() {
    dispatch(.closed)
  }

  /// A click on the card: the Voice pane of the main window, and the card goes if it had
  /// nothing left to say.
  func openConversation() {
    MainWindowRoute.shared.open(.voice)
    if case .answering(replyDone: true, speechDone: true) = turn.phase {
      dispatch(.dismissTimerFired)
    }
  }

  // MARK: - The reducer's loop

  private func dispatch(_ event: VoiceTurn.Event) {
    // Settings apply from the next question, never halfway through one.
    switch turn.phase {
    case .idle, .failed:
      turn.mode = Self.mode
      turn.speaksReplies = Self.speaksReplies
      turn.followUp = Self.followUp
    default: break
    }
    let unfinished: Bool
    switch turn.phase {
    case .thinking, .answering(replyDone: false, _): unfinished = true
    default: unfinished = false
    }
    for effect in turn.handle(event) { perform(effect) }
    VoiceShortcut.shared.setStopKey(turn.isStoppable)
    if unfinished, !exchanges.isEmpty {
      switch turn.phase {
      case .failed(let message): exchanges[exchanges.count - 1].problem = message
      case .idle: exchanges[exchanges.count - 1].wasCutOff = true
      default: break
      }
    }
    let interactive = finishedReply != nil
    if !interactive { pointerOnCard = false }
    overlay.setInteractive(interactive)
    if turn.phase != .idle { overlay.show(voice: self) }
  }

  private func perform(_ effect: VoiceTurn.Effect) {
    switch effect {
    case .startCapture: beginQuestion()
    case .finishCapture: endQuestion()
    case .cancelCapture:
      let start = starting
      Task { [capture] in
        await start?.value
        capture.cancel()
      }
    case .send(let text): ask(text)
    case .interrupt: process?.send(SupervisorArguments.interruptFrame)
    case .speak(let sentence):
      speaker.voiceIdentifier = UserDefaults.standard.string(forKey: Self.voiceKey)
      speaker.replyLanguage = Self.replyLanguage
      speaker.speak(sentence)
    case .stopSpeaking: speaker.stop()
    case .scheduleDismiss:
      dismissal?.cancel()
      // Scheduled again when the pointer leaves the card.
      guard !pointerOnCard else { return }
      dismissal = Task { [weak self] in
        try? await Task.sleep(for: Self.dismissDelay)
        guard !Task.isCancelled else { return }
        self?.dispatch(.dismissTimerFired)
      }
    case .hide:
      dismissal?.cancel()
      overlay.hide()
    }
  }

  // MARK: - Listening

  private func beginQuestion() {
    dismissal?.cancel()
    transcript = ""
    level = -160
    let answering = turn.listensForAnswer
    // An answer keeps the reply it answers on the card. `ask` clears it once the answer is sent.
    if !answering {
      question = ""
      reply = ""
      toolLabel = nil
    }
    if let problem = prerequisiteProblem() {
      dispatch(.failure(problem.localizedDescription))
      return
    }
    // Started while you speak, so the second or so `claude` takes to come up is spent before
    // the question exists rather than after.
    try? ensureProcess()
    let hints = recognitionHints()
    starting = Task { [weak self] in
      guard let self else { return }
      do {
        // Nothing cancels echo, so a microphone opened by the reply ending waits out the last of
        // the voice rather than hearing it as the start of an answer.
        if answering {
          try await Task.sleep(for: Self.answerSettle)
        }
        try await capture.start(hints: hints)
      } catch {
        dispatch(.failure(error.localizedDescription))
      }
    }
  }

  private func endQuestion() {
    let start = starting
    Task { [weak self] in
      await start?.value
      guard let self else { return }
      let text = await capture.finish()
      // A press, a failure or Settings may have ended the question while it was finishing.
      guard case .listening = turn.phase else { return }
      dispatch(.transcriptFinal(text))
    }
  }

  private func prerequisiteProblem() -> Problem? {
    guard MCPServerController.shared.runningPort != nil else { return .serverOff }
    guard account() != nil else { return .noAccount }
    guard ClaudeControl.executable() != nil else { return .noClaude }
    return nil
  }

  /// Names dictation should expect: accounts, projects and session titles, as the fleet has
  /// them right now. Read on the main actor with no I/O, as the MCP bridge reads it.
  private func recognitionHints() -> [String] {
    let snapshot = FleetBridge.build(now: Date())
    var hints = ["Armada", "Claude", "Codex"]
    for account in snapshot.claude {
      hints.append(account.name)
      for session in account.sessions {
        hints += [session.project, session.name, session.title ?? ""]
      }
    }
    for account in snapshot.codex {
      hints.append(account.name)
      for session in account.sessions {
        hints += [session.project, session.name, session.title ?? ""]
      }
    }
    var seen = Set<String>()
    return Array(
      hints.filter { !$0.isEmpty && $0.count <= 60 && seen.insert($0.lowercased()).inserted }
        .prefix(100))
  }

  // MARK: - Answering

  private func ask(_ text: String) {
    question = text
    reply = ""
    toolLabel = nil
    pendingError = nil
    chunker = SentenceChunker()
    // Before the exchange is added: a changed brief starts a new conversation, which empties the
    // list, and this question is the new conversation's first.
    let started = Result { try ensureProcess() }
    exchanges.append(VoiceExchange(question: text))
    if case .failure(let error) = started {
      dispatch(.failure(error.localizedDescription))
      return
    }
    process?.send(SupervisorArguments.userFrame(text))
  }

  private func account() -> Account? {
    let accounts = Accounts.shared
    return accounts.account(id: UserDefaults.standard.string(forKey: Self.accountKey) ?? "")
      ?? accounts.all.first
  }

  /// A running `claude` for the chosen account, started if there is none.
  private func ensureProcess() throws {
    guard let account = account() else { throw Problem.noAccount }
    let folder = account.folder
    let language = Self.replyLanguage
    let canStartSessions = MCPServerController.allowsWrites
    let style = Self.instructions
    let brief = VoiceBrief.text(
      replyingIn: language, canStartSessions: canStartSessions, style: style)
    if let process, process.isRunning, processFolder == folder.path, processBrief == brief,
      processCanStartSessions == canStartSessions
    {
      return
    }
    stopProcess()
    if let conversation, conversation.sessionToResume(folder: folder.path, brief: brief) == nil {
      // Resuming would keep the rules the conversation began with.
      self.conversation = nil
      exchanges = []
    }

    guard let executable = ClaudeControl.executable() else { throw Problem.noClaude }
    let server = MCPServerController.shared
    guard let port = server.runningPort else { throw Problem.serverOff }
    let token = server.token
    guard !token.isEmpty else { throw Problem.noToken(server.tokenError) }

    let config = try SupervisorMCPConfig.write(
      serverName: SupervisorArguments.serverName, port: port, token: token,
      in: try Self.privateDirectory(Self.configRoot))
    let directory = try Self.privateDirectory(
      Self.conversationsRoot.appending(
        path: Self.directoryName(for: folder), directoryHint: .isDirectory))
    let resume = conversation?.sessionToResume(folder: folder.path, brief: brief)

    generation += 1
    let current = generation
    let process = SupervisorProcess(
      onEvent: { event in
        MainActor.assumeIsolated { VoiceController.shared.receive(event, generation: current) }
      },
      onExit: { status, stderr in
        MainActor.assumeIsolated {
          VoiceController.shared.exited(status: status, stderr: stderr, generation: current)
        }
      })
    try process.start(
      .init(
        executable: executable,
        arguments: SupervisorArguments.arguments(
          mcpConfig: config.path(percentEncoded: false), resume: resume, replyLanguage: language,
          canStartSessions: canStartSessions, style: style),
        environment: SupervisorArguments.environment(from: ClaudeControl.environment(for: folder)),
        directory: directory))
    self.process = process
    processFolder = folder.path
    processBrief = brief
    processCanStartSessions = canStartSessions
    sawEvent = false
    resumed = resume != nil
  }

  private func stopProcess() {
    process?.stop()
    process = nil
    processFolder = nil
    processBrief = nil
    processCanStartSessions = nil
    generation += 1
  }

  private var isAnswering: Bool {
    switch turn.phase {
    case .thinking, .answering: true
    default: false
    }
  }

  private func receive(_ event: StreamEvent, generation: Int) {
    guard generation == self.generation else { return }
    sawEvent = true
    switch event {
    case .initialized(let sessionID, _, let servers):
      if let folder = processFolder, let brief = processBrief {
        conversation = VoiceConversation(folder: folder, sessionID: sessionID, brief: brief)
      }
      if servers.first(where: { $0.name == SupervisorArguments.serverName })?.status == "failed" {
        pendingError = "Claude couldn't reach Armada's MCP server."
      }
    case .textDelta(let text):
      guard isAnswering else { return }
      reply += text
      if !exchanges.isEmpty { exchanges[exchanges.count - 1].reply = reply }
      for sentence in chunker.append(text) { dispatch(.sentence(sentence)) }
    case .toolUse(let name):
      guard isAnswering else { return }
      toolLabel = ToolLabels.label(for: name)
      dispatch(.toolUse(name))
    case .apiError(let kind):
      pendingError = Self.message(forAPIError: kind)
    case .retry:
      toolLabel = "Claude is busy, trying again…"
    case .turnEnded(let end):
      // An interrupted turn ends after the card was already dismissed; there is nothing left
      // to say about it.
      guard isAnswering, !end.wasInterrupted else { return }
      for sentence in chunker.finish() { dispatch(.sentence(sentence)) }
      dispatch(
        .turnEnded(error: end.isError ? (pendingError ?? "Claude couldn't answer that.") : nil))
      pendingError = nil
    case .controlResponse, .other:
      break
    }
  }

  private func exited(status: Int32, stderr: String, generation: Int) {
    guard generation == self.generation else { return }
    process = nil
    processFolder = nil
    guard isAnswering else { return }
    // Exited before saying anything while resuming: the stored conversation is gone (cleared,
    // or its transcript deleted). Forget it and ask again on a new one, once.
    if !sawEvent, resumed {
      conversation = nil
      do {
        try ensureProcess()
        process?.send(SupervisorArguments.userFrame(question))
      } catch {
        dispatch(.failure(error.localizedDescription))
      }
      return
    }
    let line = stderr.split(whereSeparator: \.isNewline).last.map(String.init)
    dispatch(.failure(line.map { "claude stopped: \($0)" } ?? "claude stopped (status \(status))."))
  }

  static func message(forAPIError kind: String) -> String {
    switch kind {
    case "authentication_failed", "oauth_org_not_allowed": "Claude isn't signed in on that account."
    case "rate_limit": "That account has reached its usage limit."
    case "overloaded", "server_error": "Claude is overloaded right now. Try again in a moment."
    default: "Claude couldn't answer (\(kind.replacingOccurrences(of: "_", with: " ")))."
    }
  }

  // MARK: - Where things live

  /// The MCP configuration, holding the token: Armada's own temporary directory, 0700.
  private static var configRoot: URL {
    FileManager.default.temporaryDirectory.appending(path: "voice", directoryHint: .isDirectory)
  }

  /// One working directory per account, under Armada's own support directory. `claude --resume`
  /// looks a conversation up in the project folder named after the working directory, so this
  /// is what makes a follow-up find the conversation before it. Per bundle identifier, like
  /// the usage history, so a dev build and the installed copy keep separate conversations.
  private static var conversationsRoot: URL {
    (AppInfo.supportDirectory ?? FileManager.default.temporaryDirectory)
      .appending(path: "voice", directoryHint: .isDirectory)
  }

  private static func directoryName(for folder: ClaudeConfigFolder) -> String {
    folder.isDefault
      ? "default"
      : String(folder.path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
  }

  private static func privateDirectory(_ url: URL) throws -> URL {
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return url
  }
}
