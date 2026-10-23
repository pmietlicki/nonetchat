import Foundation

@MainActor private final class Fixture {
  var now = 0.0
  var allowed = true
  var visible = true
  var onAllowed: (@MainActor () -> Void)?
  var onVisible: (@MainActor () -> Void)?
  lazy var owner = LocalMediaOwnership(
    now: { [weak self] in self?.now ?? .nan },
    allowed: { [weak self] in
      guard let self else { return false }
      let callback = self.onAllowed; self.onAllowed = nil; callback?()
      return self.allowed
    },
    visible: { [weak self] in
      guard let self else { return false }
      let callback = self.onVisible; self.onVisible = nil; callback?()
      return self.visible
    })
}

private enum Failure: Error { case failed(String) }

@main private struct OwnershipTests {
  @MainActor static var checks = 0
  static let token = "abcdefghijklmnopqrstuvwx"
  static let nonce = "zyxwvutsrqponmlkjihgfedc"

  @MainActor static func check(_ value: Bool, _ message: String) throws {
    checks += 1
    if !value { throw Failure.failed(message) }
  }

  @MainActor static func reserve(_ f: Fixture,
    role: LocalMediaOwnership.Role = .monitor) throws -> LocalMediaOwnership.Key {
    guard let key = f.owner.reserve(token: token, account: "field-account", role: role)
      else { throw Failure.failed("admission unavailable") }
    try check(f.owner.matches(key), "new owner matches its scope")
    return key
  }

  @MainActor static func active(_ f: Fixture,
    role: LocalMediaOwnership.Role = .monitor) throws -> LocalMediaOwnership.Key {
    let key = try reserve(f, role: role)
    try check(f.owner.confirmPresentation(key), "native presentation confirmed")
    if role == .monitor { try check(f.owner.reserveCapture(key), "local monitor capture admitted") }
    try check(f.owner.activate(key), "native owner active")
    return key
  }

  @MainActor static func admission() throws {
    let f = Fixture()
    f.allowed = false
    try check(f.owner.reserve(token: token, account: "a", role: .monitor) == nil, "no restricted admission")
    f.allowed = true; f.visible = false
    try check(f.owner.reserve(token: token, account: "a", role: .monitor) == nil, "no hidden admission")
    f.visible = true
    for account in ["", " \n", "a\0b", String(repeating: "😀", count: 129)] {
      try check(f.owner.reserve(token: token, account: account, role: .listener) == nil,
        "invalid account rejected before ownership")
    }
    for value in ["", "abcdefghijklmnopqrstuvw!", token + "x", String(repeating: "é", count: 24)] {
      try check(f.owner.reserve(token: value, account: "a", role: .monitor) == nil,
        "144-bit ASCII capability required")
    }
    try check(!f.owner.hasOwner, "rejected requests reserve nothing")
    let key = try reserve(f)
    try check(f.owner.reserve(token: token, account: "b", role: .listener) == nil,
      "one purpose cannot replace another")
    try check(f.owner.binding(token: token, account: "other") == nil, "foreign account denied")
    try check(f.owner.binding(token: token, account: "field-account") === key, "exact local binding")
  }

  @MainActor static func roles() throws {
    let f = Fixture(); let key = try reserve(f)
    try check(!f.owner.reserveCapture(key), "no capture before indication")
    try check(f.owner.confirmPresentation(key), "indication available")
    try check(!f.owner.activate(key), "monitor cannot activate without local capture admission")
    try check(f.owner.reserveCapture(key), "capture reserved once")
    try check(!f.owner.reserveCapture(key), "duplicate acquisition refused")
    try check(f.owner.activate(key), "acquired monitor activates")
    try check(!f.owner.activate(key), "no duplicate activation")
    let listener = Fixture(); let other = try reserve(listener, role: .listener)
    try check(listener.owner.confirmPresentation(other), "listener indication")
    try check(!listener.owner.reserveCapture(other), "listener never acquires a microphone")
    try check(listener.owner.activate(other), "listening needs no local capture")
  }

  @MainActor static func recording() throws {
    let f = Fixture(); let key = try active(f)
    f.visible = false
    try check(f.owner.reserveRecording(key, nonce: nonce), "monitor may disclose remote recording in background")
    try check(f.owner.reserveRecording(key, nonce: nonce), "same recording is idempotent")
    try check(!f.owner.reserveRecording(key, nonce: token), "another recording cannot replace it")
    try check(!f.owner.confirmReleased(key), "uncertain OUTPUT retains ownership")
    try check(f.owner.requestStop(key), "local stop retires purpose")
    f.allowed = false
    try check(!f.owner.confirmRecordingReleased(key, nonce: token), "wrong nonce cannot hide recording")
    try check(f.owner.confirmRecordingReleased(key, nonce: nonce), "real closure still confirmable after retirement")
    try check(f.owner.confirmReleased(key), "closed OUTPUT and indicator release scope")
    try check(!f.owner.hasOwner, "retired owner released")
    let parent = Fixture(); let listener = try active(parent, role: .listener)
    parent.visible = false
    try check(!parent.owner.reserveRecording(listener, nonce: nonce), "no hidden parent recording gesture")
    parent.visible = true
    try check(parent.owner.reserveRecording(listener, nonce: nonce), "visible parent may reserve disclosure")
  }

  @MainActor static func clocks() throws {
    let f = Fixture(); let key = try reserve(f)
    f.now = LocalMediaOwnership.startBudgetMs - 1
    try check(f.owner.current(key), "preparation still inside existing budget")
    f.now += 1
    try check(!f.owner.current(key), "preparation expires at exact budget")
    f.now = 0
    try check(!f.owner.current(key), "old clock read cannot revive expired purpose")
    let live = Fixture(); let other = try active(live)
    live.now = .nan; live.visible = false
    try check(live.owner.current(other), "active media is independent of later clock/focus reads")
    live.allowed = false
    try check(!live.owner.current(other), "eligibility removal retires active media")
    live.allowed = true
    try check(!live.owner.current(other), "eligibility restoration never revives purpose")
    let invalid = Fixture(); invalid.now = .nan
    try check(invalid.owner.reserve(token: token, account: "a", role: .listener) == nil,
      "invalid initial continuous clock rejects admission")
  }

  @MainActor static func scopes() throws {
    let a = Fixture(), b = Fixture(); let first = try active(a); let foreign = try active(b)
    try check(!a.owner.matches(foreign), "same strings from another engine are not this capability")
    try check(!a.owner.requestStop(foreign), "foreign stop denied")
    try check(!a.owner.confirmReleased(foreign), "foreign cleanup denied")
    try check(a.owner.current(first), "other graph remains current")
    try check(a.owner.confirmReleased(first), "closed first scope released")
    let next = try active(a)
    try check(next !== first, "same token/account still create a distinct native object")
    try check(!a.owner.requestStop(first) && !a.owner.confirmReleased(first), "old callbacks cannot affect successor")
    try check(a.owner.current(next), "successor stays active")
  }

  @MainActor static func exactAccount() throws {
    let f = Fixture()
    let account = "\u{e9}"
    guard let key = f.owner.reserve(token: token, account: account, role: .listener)
      else { throw Failure.failed("valid UTF-16 account unavailable") }
    try check(f.owner.binding(token: token, account: "e\u{301}") == nil,
      "Unicode canonical equality must not merge account byte identifiers")
    try check(f.owner.binding(token: token, account: account) === key, "exact UTF-8 account retained")
  }

  @MainActor static func reentrantReads() throws {
    let f = Fixture(); let old = try active(f)
    var next: LocalMediaOwnership.Key?
    f.onAllowed = {
      if f.owner.confirmReleased(old) {
        next = f.owner.reserve(token: token, account: "field-account", role: .listener)
      }
    }
    try check(!f.owner.current(old), "reentrant policy read invalidates original key")
    guard let next else { throw Failure.failed("reentrant successor missing") }
    try check(f.owner.current(next), "old check never retires its successor")
    let g = Fixture(); var admitted: LocalMediaOwnership.Key?
    g.onVisible = { admitted = g.owner.reserve(token: token, account: "new", role: .listener) }
    try check(g.owner.reserve(token: token, account: "old", role: .monitor) == nil,
      "late visibility read cannot overwrite another admitted purpose")
    guard let admitted else { throw Failure.failed("visible callback admission missing") }
    try check(g.owner.current(admitted), "callback owner survives old admission")
  }

  @MainActor static func recordingVisibility() throws {
    let f = Fixture(); let key = try active(f, role: .listener)
    f.onVisible = { f.allowed = false }
    try check(!f.owner.reserveRecording(key, nonce: nonce),
      "visibility callback cannot admit recording after eligibility revocation")
    try check(f.owner.snapshot?.recording == nil, "revoked check owns no recording")
    let g = Fixture(); let other = try active(g, role: .listener)
    g.onVisible = { _ = g.owner.reserveRecording(other, nonce: token) }
    try check(!g.owner.reserveRecording(other, nonce: nonce),
      "reentrant recording cannot be replaced by the original gesture")
    try check(g.owner.ownsRecording(other, nonce: token), "new recording nonce remains owned")
  }

  @MainActor static func main() {
    do {
      for (name, body) in [
        ("admission", admission), ("roles", roles), ("recording", recording),
        ("clocks", clocks), ("scopes", scopes), ("exact-account", exactAccount),
        ("reentrant-reads", reentrantReads), ("recording-visibility", recordingVisibility)
      ] {
        let before = checks
        try body(); try check(checks > before, "case executes its checks")
        print("LOCAL_MEDIA_SWIFT_CASE_OK:\(name)")
      }
      print("LOCAL_MEDIA_SWIFT_OK:\(checks)")
    } catch {
      FileHandle.standardError.write(Data("LOCAL_MEDIA_SWIFT_FAILED:\(error)\n".utf8))
      exit(1)
    }
  }
}
