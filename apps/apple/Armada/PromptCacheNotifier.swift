import AppKit
import ArmadaMCP
import Foundation
import UserNotifications

/// Posts a notification when a stopped Claude session's prompt cache is about to lapse,
/// and brings the session forward when it is clicked.
///
/// **One notification per session per cache lifetime.** It is keyed by the request that
/// started the clock, so a session sitting in its last fifteen minutes is announced once
/// rather than on every tick, and a reply — which makes a new request — starts a new cycle.
///
/// **Withdrawn once it stops being true.** A banner still sitting in Notification Center
/// after you replied, or after the cache has gone cold, would be telling you to hurry
/// for something already settled either way. See `PromptCacheAlert` for which sessions
/// qualify, and `PromptCache` for why the expiry is an upper bound.
///
/// On its own tick rather than the watchers': nothing is written to a transcript while a
/// session sits idle, and idle is the only time this has anything to say. Fifteen seconds
/// is well inside the 75-second window a five-minute cache gets.
@MainActor
@Observable
final class PromptCacheNotifier: NSObject {
  static let shared = PromptCacheNotifier()
  static let interval: TimeInterval = 15
  private static let identifierPrefix = "prompt-cache."
  private nonisolated static let sessionKey = "sessionID"

  /// What macOS allows, for the settings pane to explain a refusal. Nil until asked.
  private(set) var authorization: UNAuthorizationStatus?

  /// Whether notifications for Armada are switched off in System Settings.
  var isDenied: Bool { authorization == .denied }

  /// Session id → the request whose cache a posted notification is about.
  @ObservationIgnored private var posted: [String: Date] = [:]
  @ObservationIgnored private var timer: DispatchSourceTimer?

  private var center: UNUserNotificationCenter { .current() }

  /// At launch, so a click on a notification delivered before a relaunch still lands.
  func start() {
    guard timer == nil else { return }
    center.delegate = self
    let tick = DispatchSource.makeTimerSource(queue: .main)
    tick.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
    tick.setEventHandler { MainActor.assumeIsolated { self.evaluate(now: Date()) } }
    tick.resume()
    timer = tick
    Task { await refreshAuthorization() }
  }

  /// Asks the first time a scope is chosen. macOS shows its prompt once and answers from
  /// memory after that, so calling this on every change is harmless.
  func requestAuthorization() async {
    _ = try? await center.requestAuthorization(options: [.alert, .sound])
    await refreshAuthorization()
  }

  func refreshAuthorization() async {
    authorization = await center.notificationSettings().authorizationStatus
  }

  private func evaluate(now: Date) {
    let defaults = UserDefaults.standard
    let scope =
      defaults.string(forKey: PromptCacheAlertScope.defaultsKey)
      .flatMap(PromptCacheAlertScope.init) ?? .off
    let minimum =
      defaults.object(forKey: PromptCacheAlertSize.defaultsKey) as? Int
      ?? PromptCacheAlertSize.fallback

    var live: [String: (Session, PromptCache)] = [:]
    for account in Accounts.shared.all {
      for session in account.sessions.sessions {
        if let cache = session.promptCache { live[session.id] = (session, cache) }
      }
    }

    func qualifies(_ session: Session, _ cache: PromptCache) -> Bool {
      PromptCacheAlert.shouldAlert(
        cache, isWaiting: session.state == .waiting, scope: scope, minimumTokens: minimum,
        now: now)
    }

    // Withdraw first: the session ended, was replied to, went cold, or the setting changed.
    for (id, lastRequest) in posted {
      if let (session, cache) = live[id], cache.lastRequest == lastRequest,
        qualifies(session, cache)
      {
        continue
      }
      center.removeDeliveredNotifications(withIdentifiers: [Self.identifierPrefix + id])
      posted[id] = nil
    }

    for (id, (session, cache)) in live where posted[id] == nil && qualifies(session, cache) {
      posted[id] = cache.lastRequest
      post(session: session, cache: cache, now: now)
    }
  }

  private func post(session: Session, cache: PromptCache, now: Date) {
    let content = UNMutableNotificationContent()
    content.title = session.displayName
    content.subtitle = session.registry.projectName
    content.body =
      "Prompt cache expires in \(PromptCacheAlert.remaining(cache, now: now)). "
      + "Reply before then, or the next turn re-caches \(TokenCount.short(cache.tokens)) tokens."
    content.sound = .default
    content.threadIdentifier = "prompt-cache"
    content.userInfo = [Self.sessionKey: session.id]
    center.add(
      UNNotificationRequest(
        identifier: Self.identifierPrefix + session.id, content: content, trigger: nil))
  }
}

extension PromptCacheNotifier: UNUserNotificationCenterDelegate {
  /// Shown even while Armada's popover or a window is up: that is not the session in
  /// question, and swallowing the banner there would drop the one warning asked for.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list, .sound]
  }

  /// A click goes to the session, through the same path `armada_focus_session` takes —
  /// Armada is not frontmost when a banner is clicked, which is the case that path handles.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
      let id = response.notification.request.content.userInfo[Self.sessionKey] as? String
    else { return }
    _ = await SessionFocuserBridge().focusSession(FocusSessionRequest(sessionID: id))
  }
}
