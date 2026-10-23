#if os(iOS)
import Foundation
import UIKit
import UserNotifications

@MainActor final class IOSLocalMediaPresentation: LocalMediaPresentation {
  private let center = UNUserNotificationCenter.current()
  private let actions: NotificationActions
  private var key: LocalMediaOwnership.Key?
  private var identifier: String?
  private var revision: String?
  private var stop: (@MainActor () -> Void)?
  private static let category = "nonet.local-media"
  private static let stopAction = "nonet.local-media.stop"
  // Same asynchronous system-confirmation cadence as Android LocalMediaPlugin
  // (CTS checkNotificationExistence); lifetime is the existing admission budget.
  private static let pollNanoseconds: UInt64 = 100_000_000

  init(actions: NotificationActions) {
    self.actions = actions
    actions.localMediaResponse = { [weak self] response in self?.receive(response) }
  }

  var foreground: Bool {
    UIApplication.shared.applicationState == .active && UIApplication.shared.isProtectedDataAvailable
  }

  private func authorized() async -> Bool {
    let settings = await center.notificationSettings()
    return settings.authorizationStatus == .authorized && settings.alertSetting == .enabled &&
      settings.notificationCenterSetting == .enabled
  }

  func present(_ view: LocalMediaView, stop: @escaping @MainActor () -> Void) async -> Bool {
    guard key == nil, foreground else { return false }
    key = view.key; identifier = "nonet.media." + UUID().uuidString; self.stop = stop
    return await post(view)
  }

  func update(_ view: LocalMediaView) async -> Bool {
    guard key === view.key else { return false }
    return await post(view)
  }

  private func post(_ view: LocalMediaView) async -> Bool {
    guard key === view.key, let identifier, await authorized(), key === view.key else { return false }
    let action = UNNotificationAction(identifier: Self.stopAction, title: view.stop, options: [])
    let category = UNNotificationCategory(identifier: Self.category, actions: [action],
      intentIdentifiers: [], options: .customDismissAction)
    await withCheckedContinuation { completion in
      actions.registerMediaCategory(category) { completion.resume() }
    }
    guard key === view.key else { return false }
    let version = UUID().uuidString
    revision = version
    let content = UNMutableNotificationContent()
    content.title = view.title; content.body = view.body
    content.categoryIdentifier = Self.category
    // No account, peer, session token, microphone data or recording nonce in
    // OS payloads. UUIDs map only to this engine's immutable in-memory purpose.
    content.userInfo = ["nonetLocalMedia": "v1", "nonetMediaRevision": version]
    do { try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) }
    catch { return false }
    let issued = AppleLocalMediaPlugin.continuousMs()
    while withinBudget(issued), key === view.key, revision == version {
      if await delivered(identifier: identifier, revision: version) { return key === view.key }
      do { try await Task.sleep(nanoseconds: Self.pollNanoseconds) } catch { return false }
    }
    return false
  }

  private func withinBudget(_ issued: Double) -> Bool {
    let now = AppleLocalMediaPlugin.continuousMs()
    return issued.isFinite && now.isFinite && now >= issued &&
      now - issued < LocalMediaOwnership.startBudgetMs && !Task.isCancelled
  }

  private func delivered(identifier: String, revision: String) async -> Bool {
    let values = await center.deliveredNotifications()
    return values.contains { $0.request.identifier == identifier &&
      $0.request.content.userInfo["nonetMediaRevision"] as? String == revision &&
      $0.request.content.userInfo["nonetLocalMedia"] as? String == "v1" }
  }

  func exists(_ key: LocalMediaOwnership.Key) async -> Bool {
    guard self.key === key, let identifier, let revision, await authorized() else { return false }
    let shown = await delivered(identifier: identifier, revision: revision)
    return self.key === key && self.revision == revision && shown
  }

  func remove(_ key: LocalMediaOwnership.Key) async -> Bool {
    if self.key == nil && identifier == nil { return true }
    guard self.key === key, let identifier else { return false }
    center.removePendingNotificationRequests(withIdentifiers: [identifier])
    center.removeDeliveredNotifications(withIdentifiers: [identifier])
    let issued = AppleLocalMediaPlugin.continuousMs()
    while withinBudget(issued), self.key === key {
      let pending = await center.pendingNotificationRequests()
      let delivered = await center.deliveredNotifications()
      if !pending.contains(where: { $0.identifier == identifier }) &&
          !delivered.contains(where: { $0.request.identifier == identifier }) {
        self.key = nil; self.identifier = nil; revision = nil; stop = nil
        return true
      }
      do { try await Task.sleep(nanoseconds: Self.pollNanoseconds) } catch { return false }
    }
    return false
  }

  func withdrawRecording(_ view: LocalMediaView) async -> Bool {
    if await post(view) { return true }
    // Notification permission can be revoked during recording. Once OUTPUT
    // has really closed, confirmed removal is a valid withdrawal too; never
    // require the user to restore permission merely to stop the old purpose.
    let stopping = stop
    guard await remove(view.key) else { return false }
    stopping?()
    return true
  }

  func receive(_ response: UNNotificationResponse) {
    guard key != nil, response.notification.request.identifier == identifier,
          response.notification.request.content.userInfo["nonetLocalMedia"] as? String == "v1",
          response.actionIdentifier == Self.stopAction ||
            response.actionIdentifier == UNNotificationDismissActionIdentifier else { return }
    stop?() // A tap/dismiss can only stop, never acquire or resume a microphone.
  }
}
#endif
