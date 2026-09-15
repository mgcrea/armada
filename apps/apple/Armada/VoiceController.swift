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
  /// Conversation ids by config folder path, so a follow-up after the process closed resumes.
  nonisolated static let sessionsKey = "armada.voiceSessions"

  static let dismissDelay: Duration = .seconds(6)

  static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
  static var mode: VoiceMode {
    UserDefaults.standard.string(forKey: modeKey).flatMap(VoiceMode.init(rawValue:)) ?? .press
  }
  static var speaksReplies: Bool {
    UserDefaults.standard.object(forKey: speaksKey) as? Bool ?? true
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

  @ObservationIgnored private let capture = VoiceCapture()
  @ObservationIgnored private let speaker = Speaker()
  @ObservationIgnored private let overlay = VoiceOverlay()
  @ObservationIgnored private var process: SupervisorProcess?
  @ObservationIgnored private var processFolder: String?
  /// Bumped for every process started or stopped, so a late event or exit from the one before
  /// is recognised and dropped.
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var sawEvent = false
  @ObservationIgnored private var resumed = false
  @ObservationIgnored private var chunker = SentenceChunker()
  @ObservationIgnored private var pendingError: String?
  @ObservationIgnored private var starting: Task<Void, Never>?
  @ObservationIgnored private var dismissal: Task<Void, Never>?

  private init() {
    capture.onTranscript = { [weak self] in self?.transcript = $0 }
    capture.onLevel = { [weak self] in self?.level = $0 }
    capture.onPause = { [weak self] _ in self?.dispatch(.speechEnded) }
    capture.onPreparing = { [weak self] in self?.preparingSpeech = $0 }
    speaker.onFinished = { [weak self] in self?.dispatch(.speechFinished) }
    VoiceShortcut.shared.onPress = { [weak self] in self?.dispatch(.shortcutDown) }
    VoiceShortcut.shared.onRelease = { [weak self] in self?.dispatch(.shortcutUp) }
  }

  // MARK: - Switching on and off

  /// Register the shortcut while voice is on and Armada is entitled, and stand everything
  /// down otherwise. Called by `EntitlementMonitor.apply()` and by Settings ▸ Voice.
  func sync() {
    if Self.isEnabled, EntitlementMonitor.shared.current.isEntitled {
      VoiceShortcut.shared.register(VoiceShortcut.Chord.stored)
      SpeechModelStore.shared.warmUp()
    } else {
      VoiceShortcut.shared.unregister()
      standDown()
      SpeechModelStore.shared.release()
    }
  }

  /// The next question starts a new conversation instead of continuing this one.
  func startNewConversation() {
    UserDefaults.standard.removeObject(forKey: Self.sessionsKey)
    stopProcess()
  }

  /// The account changed: the next question starts that account's own `claude`.
  func accountChanged() {
    stopProcess()
  }

  private func standDown() {
    starting?.cancel()
    capture.cancel()
    speaker.stop()
    dismissal?.cancel()
    overlay.hide()
    turn = VoiceTurn(mode: Self.mode, speaksReplies: Self.speaksReplies)
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
        finishing ? "…" : "Listening…"
      }
    case .thinking, .answering: question
    case .failed(let message): message
    }
  }

  var detail: String? {
    switch turn.phase {
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

  // MARK: - The reducer's loop

  private func dispatch(_ event: VoiceTurn.Event) {
    // Settings apply from the next question, never halfway through one.
    switch turn.phase {
    case .idle, .failed:
      turn.mode = Self.mode
      turn.speaksReplies = Self.speaksReplies
    default: break
    }
    for effect in turn.handle(event) { perform(effect) }
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
      speaker.speak(sentence)
    case .stopSpeaking: speaker.stop()
    case .scheduleDismiss:
      dismissal?.cancel()
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
    question = ""
    reply = ""
    toolLabel = nil
    level = -160
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
    do {
      try ensureProcess()
    } catch {
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
    if let process, process.isRunning, processFolder == folder.path { return }
    stopProcess()

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
    let resume = Self.sessionID(for: folder.path)

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
          mcpConfig: config.path(percentEncoded: false), resume: resume),
        environment: SupervisorArguments.environment(from: ClaudeControl.environment(for: folder)),
        directory: directory))
    self.process = process
    processFolder = folder.path
    sawEvent = false
    resumed = resume != nil
  }

  private func stopProcess() {
    process?.stop()
    process = nil
    processFolder = nil
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
      if let folder = processFolder { Self.store(sessionID: sessionID, for: folder) }
      if servers.first(where: { $0.name == SupervisorArguments.serverName })?.status == "failed" {
        pendingError = "Claude couldn't reach Armada's MCP server."
      }
    case .textDelta(let text):
      guard isAnswering else { return }
      reply += text
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
    let folder = processFolder
    process = nil
    processFolder = nil
    guard isAnswering else { return }
    // Exited before saying anything while resuming: the stored conversation is gone (cleared,
    // or its transcript deleted). Forget it and ask again on a new one, once.
    if !sawEvent, resumed, let folder {
      Self.store(sessionID: nil, for: folder)
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

  private static func sessionID(for folder: String) -> String? {
    (UserDefaults.standard.dictionary(forKey: sessionsKey) as? [String: String])?[folder]
  }

  private static func store(sessionID: String?, for folder: String) {
    var sessions =
      (UserDefaults.standard.dictionary(forKey: sessionsKey) as? [String: String]) ?? [:]
    sessions[folder] = sessionID
    UserDefaults.standard.set(sessions, forKey: sessionsKey)
  }
}
