#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif
import Foundation
import UserNotifications
import CryptoKit
import Security
import Darwin

/// One durable inbox on the existing engine. The OS may suspend/terminate that
/// engine: accepted gestures remain pending until its next ordinary startup.
final class NotificationActions: NSObject, UNUserNotificationCenterDelegate {
  private let channel: FlutterMethodChannel
  private let io = DispatchQueue(label: "com.nonetchat.notification-actions")
  private let center = UNUserNotificationCenter.current()
  private var upstream: UNUserNotificationCenterDelegate?
  private let preferences = UserDefaults.standard
  private let ownerKey = "nonet.notification.owner"
  private let maximum = 1000 // Existing private outbox bound.
  private let lifetime = 86_400_000.0 // Existing private outbox lifetime, ms.
  private var epoch = 0
  private var generation = UUID().uuidString
  private lazy var alarms = ArrivalNotifications(center: center, io: io,
    clock: continuousMs, boot: boot, owner: { self.owner }, invalidate: { self.epoch += 1 }, post: post)

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "fr.pmietlicki.nonetchat/notification_actions", binaryMessenger: messenger)
    super.init()
    if let saved = preferences.string(forKey: "nonet.notification.generation"), UUID(uuidString: saved) != nil {
      generation = saved
    } else { preferences.set(generation, forKey: "nonet.notification.generation") }
    upstream = center.delegate
    center.delegate = self
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      self.io.async {
        do {
          let args = call.arguments as? [String: Any] ?? [:]
          let value: Any?
          switch call.method {
          case "configure":
            guard let owner = args["owner"] as? String, !owner.isEmpty, owner.count <= 128 else { throw Failure.invalid }
            self.preferences.set(owner, forKey: self.ownerKey)
            value = nil
          case "arrivalRemaining": value = try self.alarms.remaining(args).map { Int64(ceil($0)) }
          case "arrivalCancel":
            guard let key = args["key"] as? String else { throw Failure.invalid }
            try self.alarms.cancel(key); value = nil
          case "journeyReconcile": try self.alarms.reconcile(args); value = nil
          case "arrivalSchedule":
            try self.alarms.schedule(args) { outcome in
              DispatchQueue.main.async {
                switch outcome {
                case .success(let armed): result(armed)
                case .failure: result(FlutterError(code: "UNAVAILABLE", message: "Arrival reminder unavailable", details: nil))
                }
              }
            }
            return
          case "takeOpen":
            let url = try self.directory().appendingPathComponent("open.json")
            if FileManager.default.fileExists(atPath: url.path) {
              let item = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String]
              try FileManager.default.removeItem(at: url)
              value = item?["owner"] == self.owner ? item?["payload"] : nil
            } else { value = nil }
          case "post":
            try self.post(args) { outcome in
              DispatchQueue.main.async {
                switch outcome {
                case .success(let shown): result(shown)
                case .failure: result(FlutterError(code: "UNAVAILABLE", message: "Notification unavailable", details: nil))
                }
              }
            }
            return
          case "pending": value = try self.pending(args)
          case "purge": try self.purge(args); value = nil
          case "complete", "deferred":
            guard let token = args["token"] as? String, var row = try self.read(token),
                  row["state"] as? Int == 1 else { DispatchQueue.main.async { result(nil) }; return }
            if call.method == "complete" {
              row["state"] = 2; row.removeValue(forKey: "input"); row.removeValue(forKey: "kind")
              try self.write(token, row)
            }
            self.feedback(token, args["feedback"] as? String ?? "")
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
  private func continuousMs() -> Double {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000
  }
  private func boot() -> String {
    var size = 0
    guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0, size < 256 else { return "" }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return "" }
    return String(cString: bytes)
  }
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
    #if os(iOS)
    let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    #else
    let options: Data.WritingOptions = [.atomic]
    #endif
    let url = try directory().appendingPathComponent(token + ".json")
    try data.write(to: url, options: options)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  private func categories(_ labels: [String: String], _ extensions: [String: Int]) throws -> (String, Set<UNNotificationCategory>) {
    for key in ["reply", "read", "coming", "where", "confirm", "extend"] {
      guard let text = labels[key], !text.isEmpty, text.count <= 500 else { throw Failure.invalid }
    }
    let encoded = try JSONSerialization.data(withJSONObject: ["labels": labels, "extensions": extensions], options: .sortedKeys)
    let suffix = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    let base = "nonet." + suffix
    // Authentication is required for actions exposing or sending private data.
    let reply = UNTextInputNotificationAction(identifier: "reply", title: labels["reply"]!, options: [.authenticationRequired],
      textInputButtonTitle: labels["reply"]!, textInputPlaceholder: labels["reply"]!)
    func action(_ key: String) -> UNNotificationAction {
      UNNotificationAction(identifier: key, title: labels[key]!, options: [.authenticationRequired])
    }
    let ordinary = UNNotificationCategory(identifier: base + ".chat", actions: [reply, action("read")], intentIdentifiers: [], options: [])
    let sos = UNNotificationCategory(identifier: base + ".sos", actions: [action("coming"), action("where"), reply], intentIdentifiers: [], options: [])
    let extend = extensions.sorted { $0.value < $1.value }.map {
      UNNotificationAction(identifier: "extend:\($0.value)", title: "\(labels["extend"]!) · \($0.key)", options: [.authenticationRequired])
    }
    let journey = UNNotificationCategory(identifier: base + ".journey", actions: [action("confirm")] + extend, intentIdentifiers: [], options: [])
    return (base, [ordinary, sos, journey])
  }
  private func post(_ args: [String: Any], completion: @escaping (Result<Bool, Error>) -> Void) throws {
    guard args["owner"] as? String == owner else { completion(.failure(Failure.invalid)); return }
    // Apple cannot exclude an individual notification from watch mirroring.
    #if os(iOS)
    if args["localOnly"] as? Bool == true { completion(.success(true)); return }
    #endif
    guard let logicalTag = args["tag"] as? String, logicalTag.hasPrefix("nonet:"),
          let title = args["title"] as? String, let body = args["body"] as? String,
          title.count <= 500, body.utf8.count <= 16000 else { throw Failure.invalid }
    // A global erasure retires ordinary request IDs as well as capabilities:
    // an asynchronous OS removal cannot erase a new notification of that chat.
    // Scheduled alarms retain their own revisioned/cancelable identifiers.
    let tag = args["scheduleSeconds"] == nil ? logicalTag + ":" + generation : logicalTag
    let content = UNMutableNotificationContent(); content.title = title; content.body = body
    content.threadIdentifier = logicalTag
    content.sound = .default // Never critical; OS Focus and sound settings win.
    // Native requests keep their full collision-resistant tag. They are routed
    // by this delegate; the macOS plugin only accepts numeric request IDs.
    content.userInfo = ["nonetOwner": owner, "nonetGeneration": generation, "payload": args["payload"] as? String ?? ""]
    var added = Set<UNNotificationCategory>()
    if let context = args["context"] as? [String: Any], let labels = args["labels"] as? [String: String] {
      guard context["owner"] as? String == owner, let scope = context["scope"] as? String,
            ["contact", "group", "journey"].contains(scope) else { throw Failure.invalid }
      if let now = args["now"] as? Double { _ = try pending(["now": now]) }
      let allFiles = try files()
      if allFiles.count >= maximum {
        // An accepted reply is never evicted to offer another button.
        guard let unused = try allFiles.first(where: { try read($0.deletingPathExtension().lastPathComponent)?["state"] as? Int != 1 }) else { throw Failure.full }
        try FileManager.default.removeItem(at: unused)
      }
      var random = [UInt8](repeating: 0, count: 18)
      guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw Failure.invalid }
      let token = Data(random).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      try write(token, ["token": token, "state": 0, "context": context, "tag": tag])
      content.userInfo["nonetToken"] = token
      let categories = try self.categories(labels, context["extensions"] as? [String: Int] ?? [:])
      added = categories.1
      content.categoryIdentifier = categories.0 + (scope == "journey" ? ".journey" : (context["sos"] as? Bool == true ? ".sos" : ".chat"))
    }
    let postEpoch = epoch
    center.getNotificationCategories { existing in
      self.io.async {
        guard postEpoch == self.epoch, args["owner"] as? String == self.owner else { completion(.failure(Failure.invalid)); return }
        self.center.setNotificationCategories(existing.union(added))
        let delay = (args["scheduleSeconds"] as? NSNumber)?.doubleValue ?? 0
        let trigger = delay > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false) : nil
        self.center.add(UNNotificationRequest(identifier: tag, content: content, trigger: trigger)) { error in
          if let error = error { completion(.failure(error)) } else { completion(.success(true)) }
        }
      }
    }
  }
  private func pending(_ args: [String: Any]) throws -> [[String: Any]] {
    let now = (args["now"] as? NSNumber)?.doubleValue
    return try files().compactMap { file in
      guard var row = try read(file.deletingPathExtension().lastPathComponent),
        let context = row["context"] as? [String: Any], context["owner"] as? String == owner,
        let issued = (context["issuedAt"] as? NSNumber)?.doubleValue else { return nil }
      if let now = now, now - issued >= lifetime {
        try FileManager.default.removeItem(at: file); return nil
      }
      guard row["state"] as? Int == 1 else { return nil }
      if row["gestureAt"] == nil, let now = now {
        let elapsed = continuousMs() - ((row["acceptedContinuous"] as? NSNumber)?.doubleValue ?? -1)
        let sameBoot = !boot().isEmpty && row["acceptedBoot"] as? String == boot()
        row["gestureAt"] = sameBoot && elapsed >= 0 ? max(issued, now - elapsed) : issued
        try write(row["token"] as! String, row)
      }
      return row
    }
  }
  private func purge(_ args: [String: Any]) throws {
    epoch += 1
    if !["scope", "target", "reference"].contains(where: { args[$0] is String }) {
      generation = UUID().uuidString
      preferences.set(generation, forKey: "nonet.notification.generation")
      try alarms.purge(owner: owner)
      let open = try directory().appendingPathComponent("open.json")
      if FileManager.default.fileExists(atPath: open.path) { try FileManager.default.removeItem(at: open) }
      let barrier = generation, account = owner
      // Context-free public alerts also belong to the erased history. Preserve
      // notifications published after this barrier, including after a restart.
      center.getDeliveredNotifications { values in
        self.io.async {
          guard self.generation == barrier, self.owner == account else { return }
          let ids = values.filter {
            $0.request.content.userInfo["nonetOwner"] as? String == account &&
              $0.request.content.userInfo["nonetGeneration"] as? String != barrier
          }.map { $0.request.identifier }
          self.center.removeDeliveredNotifications(withIdentifiers: ids)
        }
      }
    }
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
  private func feedback(_ token: String, _ text: String) {
    guard !text.isEmpty, text.count <= 500 else { return }
    let generation = epoch
    center.getDeliveredNotifications { notifications in
      self.io.async {
        guard generation == self.epoch, let row = try? self.read(token),
          let ctx = row["context"] as? [String: Any], ctx["owner"] as? String == self.owner,
          let item = notifications.first(where: { $0.request.content.userInfo["nonetToken"] as? String == token }),
          let content = item.request.content.mutableCopy() as? UNMutableNotificationContent else { return }
        content.body = text; content.sound = nil; content.categoryIdentifier = ""
        self.center.add(UNNotificationRequest(identifier: item.request.identifier, content: content, trigger: nil))
      }
    }
  }
  static func owns(_ response: UNNotificationResponse) -> Bool {
    response.notification.request.content.userInfo["nonetOwner"] is String
  }
  func receive(_ response: UNNotificationResponse, completion: @escaping () -> Void) {
    io.async {
      defer { DispatchQueue.main.async(execute: completion) }
      let info = response.notification.request.content.userInfo
      if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
        guard info["nonetOwner"] as? String == self.owner,
          let payload = info["payload"] as? String, !payload.isEmpty, payload.utf8.count <= 4096 else { return }
        do {
          let data = try JSONSerialization.data(withJSONObject: ["owner": self.owner, "payload": payload])
          let url = try self.directory().appendingPathComponent("open.json")
          #if os(iOS)
          try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
          #else
          try data.write(to: url, options: [.atomic])
          #endif
          try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { return }
        DispatchQueue.main.async { self.channel.invokeMethod("pending", arguments: nil) }
        return
      }
      guard let token = info["nonetToken"] as? String,
        var row = try? self.read(token), row["state"] as? Int == 0,
        let ctx = row["context"] as? [String: Any], ctx["owner"] as? String == self.owner else { return }
      var kind = response.actionIdentifier
      var input = (response as? UNTextInputNotificationResponse)?.userText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if kind.hasPrefix("extend:"), let seconds = Int(kind.dropFirst(7)),
          let choices = ctx["extensions"] as? [String: Int], let label = choices.first(where: { $0.value == seconds })?.key {
        kind = "extend"; input = label
      }
      let permitted = ctx["scope"] as? String == "journey"
        ? ["confirm", "extend"] : (ctx["sos"] as? Bool == true ? ["reply", "read", "coming", "where"] : ["reply", "read"])
      guard permitted.contains(kind), input.utf8.count <= 12000, kind != "reply" || !input.isEmpty else { return }
      row["state"] = 1; row["kind"] = kind; row["input"] = input
      row["acceptedContinuous"] = self.continuousMs(); row["acceptedBoot"] = self.boot()
      do { try self.write(token, row) } catch { return }
      DispatchQueue.main.async { self.channel.invokeMethod("pending", arguments: nil) }
    }
  }
  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void) {
    if Self.owns(response) { receive(response, completion: completionHandler) }
    else if let upstream = upstream, upstream.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))) {
      upstream.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler)
    } else { completionHandler() }
  }
  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    if notification.request.content.userInfo["nonetOwner"] is String {
      completionHandler([.banner, .list, .sound])
    } else if let upstream = upstream, upstream.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))) {
      upstream.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
    } else { completionHandler([]) }
  }
}
