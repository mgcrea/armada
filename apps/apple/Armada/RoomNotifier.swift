import Foundation
import UserNotifications

/// The one notification a room posts, when every seat has posted done.
///
/// **Why once.** A room outlives the turn that opened it. The person hears that the
/// investigation is finished without opening anything, and only on the post that completed it.
/// `nonisolated` because the bridge calls it off the main actor. Only strings cross in.
///
/// **Never waits on a person.** The post is already stored when this runs, so an answer held
/// up by the permission prompt could time out and be retried. Undetermined, the request goes
/// on in its own task. Denied, this returns without throwing.
nonisolated enum RoomNotifier {
  static func post(room name: String) async {
    let title = "Room \(name)"
    let body = "Every seat has posted done."
    let identifier = "room-\(name)-done"
    let center = UNUserNotificationCenter.current()
    switch await center.notificationSettings().authorizationStatus {
    case .denied:
      return
    case .notDetermined:
      Task {
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
          return
        }
        await add(title: title, body: body, identifier: identifier)
      }
    default:
      await add(title: title, body: body, identifier: identifier)
    }
  }

  private static func add(title: String, body: String, identifier: String) async {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.threadIdentifier = "rooms"
    try? await UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
  }
}
