import Flutter
import Foundation
import UserNotifications
import CryptoKit
import Security

/// Uses the application's existing engine and application delegate. Never
/// registers a Dart background callback or creates a headless Flutter engine.
final class NotificationActions {
  private let channel: FlutterMethodChannel
  private let io = DispatchQueue(label: "com.nonetchat.notification-actions")
  private let center = UNUserNotificationCenter.current()
  private let preferences = UserDefaults.standard
  private let ownerKey = "nonet.notification.owner"
  private let maximum = 1000 // Existing private outbox global bound.
  private let lifetime = 86_400_000.0 // Existing private outbox lifetime in ms.

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "fr.pmietlicki.nonetchat/notification_actions", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      self.io.async {
        do {
          let args = call.arguments as? [String: Any] ?? [:]
          let value: Any?
          switch call.method {
          case "configure":
            guard let owner = args["owner"] as? String, !owner.isEmpty, owner.count <= 128 else { throw Failure.invalid }
            self.preferences.set(owner, forKey: self.ownerKey)
            value = nil
          case "post": value = try self.post(args)
          case "pending": value = try self.pending()
          case "purge": try self.purge(args); value = nil
          case "complete", "deferred":
            guard let token = args["token"] as? String, var row = try self.read(token),
                  row["state"] as? Int == 1 else { DispatchQueue.main.async { result(nil) }; return }
            if call.method == "complete" {
              row["state"] = 2; row.removeValue(forKey: "input"); try self.write(token, row)
            }
            value = nil
          default: DispatchQueue.main.async { result(FlutterMethodNotImplemented) }; return
          }
          DispatchQueue.main.async { result(value) }
        } catch {
          DispatchQueue.main.async { result(FlutterError(code: "UNAVAILABLE", message: "Notification action unavailable", details: nil)) }
        }
      }
    }
  }

  private enum Failure: Error { case invalid, full }
  private var owner: String { preferences.string(forKey: ownerKey) ?? "" }
  private func tokenValid(_ token: String) -> Bool {
    token.range(of: "^[A-Za-z0-9_-]{24}$", options: .regularExpression) != nil
  }
  private func directory() throws -> URL {
    let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    var url = root.appendingPathComponent("NoNetNotificationActions", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
    try url.setResourceValues(excluded)
    return url
  }
  private func files() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" && tokenValid($0.deletingPathExtension().lastPathComponent) }
  }
  private func read(_ token: String) throws -> [String: Any]? {
    guard tokenValid(token) else { return nil }
    let url = try directory().appendingPathComponent(token + ".json")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
  }
  private func write(_ token: String, _ row: [String: Any]) throws {
    guard tokenValid(token) else { throw Failure.invalid }
    let data = try JSONSerialization.data(withJSONObject: row)
    guard data.count <= 16384 + 12000 + 8192 else { throw Failure.invalid }
    try data.write(to: directory().appendingPathComponent(token + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }
  private func categories(_ labels: [String: String], _ extensions: [String: Int]) throws -> (String, Set<UNNotificationCategory>) {
    for key in ["reply", "read", "coming", "where", "confirm", "extend"] {
      guard let text = labels[key], !text.isEmpty, text.count <= 500 else { throw Failure.invalid }
    }
    let encoded = try JSONSerialization.data(withJSONObject: ["labels": labels, "extensions": extensions], options: .sortedKeys)
    let suffix = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    let base = "nonet." + suffix
    let reply = UNTextInputNotificationAction(identifier: "reply", title: labels["reply"]!, options: [],
      textInputButtonTitle: labels["reply"]!, textInputPlaceholder: labels["reply"]!)
    func action(_ key: String) -> UNNotificationAction {
      UNNotificationAction(identifier: key, title: labels[key]!, options: [])
    }
    let ordinary = UNNotificationCategory(identifier: base + ".chat", actions: [reply, action("read")], intentIdentifiers: [], options: [])
    let sos = UNNotificationCategory(identifier: base + ".sos", actions: [action("coming"), action("where"), reply], intentIdentifiers: [], options: [])
    let extend = extensions.sorted { $0.value < $1.value }.map {
      UNNotificationAction(identifier: "extend:\($0.value)", title: "\(labels["extend"]!) · \($0.key)", options: [])
    }
    let journey = UNNotificationCategory(identifier: base + ".journey", actions: [action("confirm")] + extend, intentIdentifiers: [], options: [])
    return (base, [ordinary, sos, journey])
  }
  private func post(_ args: [String: Any]) throws -> Bool {
    guard args["owner"] as? String == owner else { return true }
    // iOS has no per-notification setLocalOnly counterpart. Keep technical
    // status inside the app rather than mirroring it to the watch.
    if args["localOnly"] as? Bool == true { return true }
    guard let tag = args["tag"] as? String, tag.hasPrefix("nonet:"),
          let title = args["title"] as? String, let body = args["body"] as? String,
          title.count <= 500, body.utf8.count <= 16000 else { throw Failure.invalid }
    let content = UNMutableNotificationContent(); content.title = title; content.body = body
    content.threadIdentifier = tag
    content.userInfo = ["nonetOwner": owner, "payload": args["payload"] as? String ?? ""]
    if let context = args["context"] as? [String: Any], let labels = args["labels"] as? [String: String] {
      guard context["owner"] as? String == owner, let scope = context["scope"] as? String,
            ["contact", "group", "journey"].contains(scope) else { throw Failure.invalid }
      let allFiles = try files()
      if allFiles.count >= maximum {
        // Never evict an accepted reply. Retire one unused/completed capability.
        guard let unused = try allFiles.first(where: { try read($0.deletingPathExtension().lastPathComponent)?["state"] as? Int != 1 }) else { throw Failure.full }
        try FileManager.default.removeItem(at: unused)
      }
      var random = [UInt8](repeating: 0, count: 18)
      guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw Failure.invalid }
      let token = Data(random).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      try write(token, ["token": token, "state": 0, "context": context, "tag": tag])
      content.userInfo["nonetToken"] = token
      let (base, added) = try categories(labels, context["extensions"] as? [String: Int] ?? [:])
      content.categoryIdentifier = base + (scope == "journey" ? ".journey" : (context["sos"] as? Bool == true ? ".sos" : ".chat"))
      center.getNotificationCategories { existing in
        self.center.setNotificationCategories(existing.union(added))
        self.center.add(UNNotificationRequest(identifier: tag, content: content, trigger: nil))
      }
      return true
    }
    center.add(UNNotificationRequest(identifier: tag, content: content, trigger: nil))
    return true
  }
  private func pending() throws -> [[String: Any]] {
    try files().compactMap { file in
      guard let row = try? read(file.deletingPathExtension().lastPathComponent), row["state"] as? Int == 1,
        let context = row["context"] as? [String: Any], context["owner"] as? String == owner else { return nil }
      return row
    }
  }
  private func purge(_ args: [String: Any]) throws {
    var tags = Set<String>()
    for file in try files() {
      guard let row = try read(file.deletingPathExtension().lastPathComponent),
            let ctx = row["context"] as? [String: Any], ctx["owner"] as? String == owner else { continue }
      if ["scope", "target", "reference"].contains(where: { args[$0] is String && args[$0] as? String != ctx[$0] as? String }) { continue }
      if let tag = row["tag"] as? String { tags.insert(tag) }
      try FileManager.default.removeItem(at: file)
    }
    center.removeDeliveredNotifications(withIdentifiers: Array(tags))
    center.removePendingNotificationRequests(withIdentifiers: Array(tags))
  }
  static func owns(_ response: UNNotificationResponse) -> Bool {
    response.notification.request.content.userInfo["nonetToken"] is String
  }
  func receive(_ response: UNNotificationResponse, completion: @escaping () -> Void) {
    io.async {
      defer { DispatchQueue.main.async(execute: completion) }
      guard let token = response.notification.request.content.userInfo["nonetToken"] as? String,
        var row = try? self.read(token), row["state"] as? Int == 0,
        let ctx = row["context"] as? [String: Any], ctx["owner"] as? String == self.owner,
        let issued = ctx["issuedAt"] as? NSNumber else { return }
      var kind = response.actionIdentifier
      var input = (response as? UNTextInputNotificationResponse)?.userText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if kind.hasPrefix("extend:"), let seconds = Int(kind.dropFirst(7)),
          let choices = ctx["extensions"] as? [String: Int], let label = choices.first(where: { $0.value == seconds })?.key {
        kind = "extend"; input = label
      }
      guard ["reply", "read", "coming", "where", "confirm", "extend"].contains(kind), input.utf8.count <= 12000 else { return }
      row["state"] = 1; row["kind"] = kind; row["input"] = input
      // Conservative fallback until the common Apple continuous-clock bridge
      // is validated: a later retry never grants fresh recognition or time.
      row["gestureAt"] = issued
      do { try self.write(token, row) } catch { return }
      DispatchQueue.main.async { self.channel.invokeMethod("pending", arguments: nil) }
    }
  }
}
