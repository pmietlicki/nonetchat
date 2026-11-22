// Native admission only: no Flutter, radio, microphone, recording or persistence.
// Shared by iOS/macOS. All mutable state stays on the platform's main actor.
@MainActor final class LocalMediaOwnership {
  enum Role { case monitor, listener }

  final class Key {
    let token: String
    let account: String
    fileprivate let issuer: LocalMediaIssuer
    fileprivate init(token: String, account: String, issuer: LocalMediaIssuer) {
      self.token = token; self.account = account; self.issuer = issuer
    }
  }

  struct Claim {
    let key: Key
    let role: Role
    let issuedAt: Double
    var presented = false
    var acquiring = false
    var active = false
    var retired = false
    var recording: String?
  }

  // Android LocalMediaOwnership.START_BUDGET_MS and the Windows owner use the
  // same 20-second local admission budget. Never expire an active media owner.
  static let startBudgetMs = 20_000.0
  typealias Clock = @MainActor () -> Double
  typealias Check = @MainActor () -> Bool
  private let now: Clock
  private let allowed: Check
  private let visible: Check
  private let issuer = LocalMediaIssuer()
  private var claim: Claim?

  init(now: @escaping Clock, allowed: @escaping Check, visible: @escaping Check) {
    self.now = now; self.allowed = allowed; self.visible = visible
  }

  var snapshot: Claim? { claim }
  var hasOwner: Bool { claim != nil }

  func reserve(token: String, account: String, role: Role) -> Key? {
    guard claim == nil, Self.validToken(token), !account.isEmpty,
          account.utf16.count <= 256, !account.utf16.contains(0),
          !account.utf16.allSatisfy({ $0 <= 32 }),
          allowed(), visible() else { return nil }
    let issuedAt = now()
    // Injected platform reads may reenter a callback. Do not overwrite a new
    // owner admitted by that callback or accept an unavailable clock.
    guard claim == nil, issuedAt.isFinite, issuedAt >= 0 else { return nil }
    let key = Key(token: token, account: account, issuer: issuer)
    claim = Claim(key: key, role: role, issuedAt: issuedAt)
    return key
  }

  func binding(token: String, account: String) -> Key? {
    guard let key = claim?.key, key.token == token,
          key.account.utf8.elementsEqual(account.utf8) else { return nil }
    return key
  }

  func matches(_ key: Key) -> Bool {
    key.issuer === issuer && claim?.key === key
  }

  func current(_ key: Key) -> Bool {
    guard matches(key), claim?.retired == false else { return false }
    guard allowed(), matches(key), claim?.retired == false else {
      _ = requestStop(key); return false
    }
    if let owner = claim, !owner.active {
      let shown = visible()
      let instant = now()
      guard matches(key), claim?.retired == false else { return false }
      guard shown, instant.isFinite, instant >= owner.issuedAt,
            instant - owner.issuedAt < Self.startBudgetMs else {
        _ = requestStop(key); return false
      }
    }
    return matches(key) && claim?.retired == false
  }

  func confirmPresentation(_ key: Key) -> Bool {
    guard current(key) else { return false }
    claim?.presented = true; return true
  }

  func reserveCapture(_ key: Key) -> Bool {
    guard current(key), let owner = claim, owner.presented,
          owner.role == .monitor, !owner.active, !owner.acquiring else { return false }
    claim?.acquiring = true; return true
  }

  func activate(_ key: Key) -> Bool {
    guard current(key), let owner = claim, owner.presented, !owner.active,
          owner.role == .listener || owner.acquiring else { return false }
    claim?.active = true; claim?.acquiring = false; return true
  }

  func reserveRecording(_ key: Key, nonce: String) -> Bool {
    guard current(key), let owner = claim, owner.active, owner.presented,
          Self.validToken(nonce), owner.recording == nil || owner.recording == nonce else { return false }
    if owner.role == .listener {
      guard visible(), current(key) else { return false }
    }
    // A visibility callback may retire the purpose or admit another recording.
    // Re-read ownership instead of writing the snapshot taken before that call.
    guard matches(key), let latest = claim, !latest.retired, latest.active,
          latest.presented, latest.recording == nil || latest.recording == nonce else { return false }
    claim?.recording = nonce; return true
  }

  func ownsRecording(_ key: Key, nonce: String) -> Bool {
    matches(key) && claim?.recording == nonce
  }

  // The caller has positively confirmed OUTPUT closure and its native
  // indication change. This remains possible after eligibility/route loss.
  func confirmRecordingReleased(_ key: Key, nonce: String) -> Bool {
    guard ownsRecording(key, nonce: nonce) else { return false }
    claim?.recording = nil; return true
  }

  @discardableResult func requestStop(_ key: Key) -> Bool {
    guard matches(key) else { return false }
    claim?.retired = true; return true
  }

  // Native media and indicator release are confirmed by the platform caller.
  // A failed confirmation must retain this owner rather than admit a successor.
  func confirmReleased(_ key: Key) -> Bool {
    guard matches(key), claim?.recording == nil else { return false }
    claim = nil; return true
  }

  nonisolated static func validToken(_ token: String) -> Bool {
    token.utf8.count == 24 && token.utf8.allSatisfy {
      (65...90).contains($0) || (97...122).contains($0) ||
      (48...57).contains($0) || $0 == 95 || $0 == 45
    }
  }
}

fileprivate final class LocalMediaIssuer {}
