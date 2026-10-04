import SwiftUI

#if DEBUG

  import AppKit

  /// What each of `appshot record`'s cues means for Armada, performed through demo
  /// mode's own state.
  ///
  /// `appshot record` launches a screenshot stage, writes named cues to a file, and films
  /// what the app does with them. Nothing is clicked or typed: the pointer in the video is
  /// drawn afterwards from the rects reported here. `AppShotCues` is the file plumbing;
  /// this is the switch.
  ///
  /// **Inert unless a take is running.** `AppShotCues.start` returns nil without the
  /// cue and event file arguments, so a screenshot capture and an ordinary Debug launch
  /// never watch anything, and the whole type is `#if DEBUG` like `DemoSeed`. Every cue
  /// moves fixture state only: the stores were seeded by `DemoSeed`, nothing here reads
  /// a folder, and nothing is written but the event file.
  @MainActor
  @Observable
  final class DemoCues {
    static let shared = DemoCues()

    /// Whether this launch is a recorded take. Read by `demoTarget(_:)` in every view
    /// that might be pointed at, so it is a constant rather than a defaults read per body.
    nonisolated static let isRecording: Bool =
      DemoSeed.isEnabled && UserDefaults.standard.string(forKey: "ScreenshotCueFile") != nil

    /// The sidebar a `stage` cue moved to, which `MainWindowView` reads before the
    /// stored selection.
    ///
    /// In memory because the stored one cannot move: `DemoSeed` pins it in the argument
    /// domain, which outranks anything written, and writing it would persist a capture's
    /// selection into the Debug build's defaults besides.
    var sidebar: SidebarItem?

    /// The elements a pointer cue or a zoom can name, in the config's words. The views
    /// register under `key`, which is the id they already have.
    enum Target: String {
      /// The storefront session: running a tool on the stage, waiting after `armada.wait`.
      case checkoutSession = "checkout-session"
      /// The Acme Corp card on the Usage pane, the one with a forecast to point at.
      case acmeUsage = "acme-usage"

      var key: String {
        switch self {
        case .checkoutSession: DemoTargetKey.session(DemoSeed.Fixture.checkoutSessionID)
        case .acmeUsage: DemoTargetKey.usage(DemoSeed.Fixture.acme.path)
        }
      }

      var session: String? {
        switch self {
        case .checkoutSession: DemoSeed.Fixture.checkoutSessionID
        case .acmeUsage: nil
        }
      }
    }

    @ObservationIgnored private var handler: AppShotCues?
    @ObservationIgnored fileprivate var anchors: [String: Weak] = [:]

    fileprivate struct Weak {
      weak var view: NSView?
    }

    private init() {}

    /// From `DemoSeed.apply()`, before any window is built.
    func start() {
      handler = AppShotCues.start { [unowned self] cue in self.perform(cue) }
    }

    /// From `DemoSeed.signalReady(from:)`, once the stage's screen has rendered.
    func ready() {
      handler?.ready()
    }

    private func perform(_ cue: AppShotCues.Cue) -> AppShotCues.Outcome {
      switch cue.name {
      case "stage":
        guard let to = cue.string("to"), let stage = DemoSeed.Stage(rawValue: to),
          let item = stage.sidebar
        else { return .unknown }
        sidebar = item
        return .done

      case "pointer.move", "pointer.click":
        guard let name = cue.string("target"), let target = Target(rawValue: name),
          let rect = rect(of: target)
        else { return .unknown }
        if cue.name == "pointer.click", let session = target.session {
          // What the click would do: select the row. The route, not the row's own
          // `@State`, which nothing outside the pane can reach.
          MainWindowRoute.shared.selectForDemo(
            .account(DemoSeed.Fixture.acme.path), session: session)
        }
        return .target(name: name, rect: rect)

      case "armada.wait":
        guard let name = cue.string("target"), let id = Target(rawValue: name)?.session,
          let session = Accounts.shared.all.lazy.flatMap(\.sessions.sessions)
            .first(where: { $0.id == id })
        else { return .unknown }
        DemoSeed.wait(session, for: cue.string("for") ?? DemoSeed.Fixture.checkoutWaitingFor)
        return .done

      default:
        return .unknown
      }
    }

    /// The part of the target's view that is on screen, in the global top-left points
    /// appshot wants. Clipped to the window, so a card running past the bottom edge
    /// points at what can be seen of it rather than somewhere below the stage.
    private func rect(of target: Target) -> CGRect? {
      guard let view = anchors[target.key]?.view, let window = view.window,
        let content = window.contentView
      else { return nil }
      let visible = view.convert(content.bounds, from: content).intersection(view.bounds)
      guard !visible.isEmpty else { return nil }
      return AppShotCues.screenRect(of: view, rect: visible)
    }
  }

  /// An empty view behind a target that tells `DemoCues` where it is.
  private struct DemoAnchor: NSViewRepresentable {
    let key: String

    final class Anchor: NSView {
      override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Anchor {
      let view = Anchor()
      DemoCues.shared.anchors[key] = .init(view: view)
      return view
    }

    // Again on every update: a row rebuilt for a new list gets a new view.
    func updateNSView(_ view: Anchor, context: Context) {
      DemoCues.shared.anchors[key] = .init(view: view)
    }
  }

#endif

/// The names a view registers under for a recorded take, shared by `demoTarget(_:)` and
/// `DemoCues.Target`. Compiled everywhere because the views that register are.
nonisolated enum DemoTargetKey {
  static func session(_ id: String) -> String { "session:\(id)" }
  static func usage(_ accountID: String) -> String { "usage:\(accountID)" }
}

extension View {
  /// Makes this view something a recorded take's pointer and zoom can find, under `key`.
  ///
  /// Nothing at all outside a take, and in every Release build — the same shape as
  /// `screenshotSubject()`.
  @ViewBuilder func demoTarget(_ key: String) -> some View {
    #if DEBUG
      if DemoCues.isRecording {
        background(DemoAnchor(key: key))
      } else {
        self
      }
    #else
      self
    #endif
  }
}
