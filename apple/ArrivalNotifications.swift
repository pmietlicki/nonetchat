import Foundation
import UserNotifications

/// Relative native reminders. No sender wall time or trip note is stored here.
/// iOS has a 64-request limit: report capacity failure rather than losing alarms.
final class ArrivalNotifications {
  private let center: UNUserNotificationCenter
  private let io: DispatchQueue
  private let clock: () -> Double
  private let boot: () -> String
  private let owner: () -> String
  private let invalidate: () -> Void
  private var arming = [String: String]()
  private let post: ([String: Any], @escaping (Result<Bool, Error>) -> Void) throws -> Void
  init(center: UNUserNotificationCenter, io: DispatchQueue, clock: @escaping () -> Double,
       boot: @escaping () -> String, owner: @escaping () -> String, invalidate: @escaping () -> Void,
       post: @escaping ([String: Any], @escaping (Result<Bool, Error>) -> Void) throws -> Void) {
    self.center = center; self.io = io; self.clock = clock; self.boot = boot; self.owner = owner; self.invalidate = invalidate; self.post = post
  }
  private enum Failure: Error { case invalid, full }
  private func valid(_ key: String) -> Bool { key.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
  private func root() throws -> URL {
    let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    var url = support.appendingPathComponent("NoNetArrivalAlarms", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    var values = URLResourceValues(); values.isExcludedFromBackup = true; try url.setResourceValues(values)
    return url
  }
  private func read(_ key: String) throws -> [String: Any]? {
    guard valid(key) else { throw Failure.invalid }
    let url = try root().appendingPathComponent(key + ".json")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
  }
  private func write(_ key: String, _ value: [String: Any]) throws {
    guard valid(key) else { throw Failure.invalid }
    let url = try root().appendingPathComponent(key + ".json")
    #if os(iOS)
    let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    #else
    let options: Data.WritingOptions = [.atomic]
    #endif
    try JSONSerialization.data(withJSONObject: value).write(to: url, options: options)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  func remaining(_ args: [String: Any]) throws -> Double? {
    guard let key = args["key"] as? String, let revision = args["revision"] as? Int else { throw Failure.invalid }
    guard let row = try read(key), row["owner"] as? String == owner(), row["revision"] as? Int == revision else { return nil }
    guard !boot().isEmpty, row["boot"] as? String == boot(), let deadline = row["deadline"] as? Double else {
      // A reboot cannot turn a saved sender wall time into an early alarm.
      if let tag = row["tag"] as? String { center.removePendingNotificationRequests(withIdentifiers: [tag]) }
      return nil
    }
    return max(0, deadline - clock())
  }
  func schedule(_ args: [String: Any], completion: @escaping (Result<Bool, Error>) -> Void) throws {
    guard !owner().isEmpty, args["owner"] as? String == owner(),
      let key = args["key"] as? String, valid(key), let revision = args["revision"] as? Int,
      let duration = (args["remainingMs"] as? NSNumber)?.doubleValue, duration.isFinite, duration >= 0,
      let title = args["title"] as? String, title.count <= 500,
      let body = args["body"] as? String, body.count <= 2000 else { throw Failure.invalid }
    if let row = try read(key), row["owner"] as? String == owner(), row["revision"] as? Int == revision,
      !boot().isEmpty, row["boot"] as? String == boot() { completion(.success(true)); return }
    let context = args["presentation"] as? [String: Any]
    let tag = context?["tag"] as? String ?? "nonet:arrival:\(key)"
    guard tag.hasPrefix("nonet:") else { throw Failure.invalid }
    invalidate()
    let nonce = UUID().uuidString
    try write(key, ["owner": owner(), "revision": revision, "deadline": clock() + duration,
      "boot": boot(), "tag": tag, "nonce": nonce, "journey": context != nil])
    arming[tag] = nonce
    let finish: (Result<Bool, Error>) -> Void = { outcome in
      self.io.async {
        if self.arming[tag] == nonce { self.arming.removeValue(forKey: tag) }
        completion(outcome)
      }
    }
    center.getPendingNotificationRequests { requests in
      self.io.async {
        do {
          guard let row = try self.read(key), row["nonce"] as? String == nonce, row["owner"] as? String == self.owner() else {
            finish(.success(true)); return
          }
          // Reserve in-flight admissions as well as requests already in the OS.
          guard Set(requests.map { $0.identifier }).union(self.arming.keys).count <= 64 else { throw Failure.full }
          var presentation = context ?? [:]
          presentation["owner"] = self.owner(); presentation["tag"] = tag
          presentation["title"] = title; presentation["body"] = body
          presentation["id"] = 1
          presentation["scheduleSeconds"] = duration / 1000
          // No source note, name or coordinates; only open the emergency page.
          let payload: [String: String] = ["action": "OPEN_EMERGENCY_ACTIVITY", "owner": self.owner()]
          presentation["payload"] = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
          try self.post(presentation) { outcome in
            self.io.async {
              if case .failure = outcome, let current = try? self.read(key), current["nonce"] as? String == nonce {
                try? FileManager.default.removeItem(at: self.root().appendingPathComponent(key + ".json"))
              }
              finish(outcome)
            }
          }
        } catch {
          if let current = try? self.read(key), current["nonce"] as? String == nonce {
            try? FileManager.default.removeItem(at: self.root().appendingPathComponent(key + ".json"))
          }
          finish(.failure(error))
        }
      }
    }
  }
  func cancel(_ key: String) throws {
    guard let row = try read(key) else { return }
    invalidate()
    if let tag = row["tag"] as? String {
      center.removePendingNotificationRequests(withIdentifiers: [tag]); center.removeDeliveredNotifications(withIdentifiers: [tag])
    }
    try FileManager.default.removeItem(at: root().appendingPathComponent(key + ".json"))
  }
  func purge(owner: String) throws {
    for file in try FileManager.default.contentsOfDirectory(at: root(), includingPropertiesForKeys: nil) {
      let key = file.deletingPathExtension().lastPathComponent
      guard valid(key), let row = try read(key), row["owner"] as? String == owner else { continue }
      try cancel(key)
    }
  }
  func reconcile(_ args: [String: Any]) throws {
    let keep = args["keep"] as? String
    for file in try FileManager.default.contentsOfDirectory(at: root(), includingPropertiesForKeys: nil) {
      let key = file.deletingPathExtension().lastPathComponent
      guard valid(key), let row = try read(key), row["journey"] as? Bool == true else { continue }
      if row["owner"] as? String != owner() || key != keep { try cancel(key) }
    }
  }
}
