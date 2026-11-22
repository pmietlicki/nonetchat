// Typed, main-actor platform boundary. No Flutter or media SDK is imported here.
// Asynchronous native UI confirmations never grant a different/retired purpose.
@MainActor protocol LocalMediaPresentation: AnyObject {
  var foreground: Bool { get }
  func present(_ view: LocalMediaView, stop: @escaping @MainActor () -> Void) async -> Bool
  func update(_ view: LocalMediaView) async -> Bool
  func withdrawRecording(_ view: LocalMediaView) async -> Bool
  func exists(_ key: LocalMediaOwnership.Key) async -> Bool
  func remove(_ key: LocalMediaOwnership.Key) async -> Bool
}

extension LocalMediaPresentation {
  func withdrawRecording(_ view: LocalMediaView) async -> Bool { await update(view) }
}

@MainActor struct LocalMediaView {
  let key: LocalMediaOwnership.Key
  let title: String
  let body: String
  let stop: String
  let stopping: String
  let rightToLeft: Bool

  func with(body: String) -> Self {
    Self(key: key, title: title, body: body, stop: stop,
      stopping: stopping, rightToLeft: rightToLeft)
  }
}

@MainActor final class LocalMediaHost {
  typealias Key = LocalMediaOwnership.Key
  private let platform: LocalMediaPresentation
  private let clock: LocalMediaOwnership.Clock
  private var normalMode = false
  private var closing = false
  private var detached = false
  private lazy var owner = LocalMediaOwnership(now: clock,
    allowed: { [weak self] in
      guard let self else { return false }
      return self.normalMode && !self.closing && !self.detached
    }, visible: { [weak self] in self?.platform.foreground ?? false })
  private var base: LocalMediaView?
  private var recordingBody: String?
  private var pending: Task<Bool, Never>?
  private var pendingID: Int = 0
  private var releasing: Task<Bool, Never>?
  private var notifyingStop: Key?
  var onStop: (@MainActor (Key) -> Void)?
  var onDrained: (@MainActor () -> Void)?

  init(platform: LocalMediaPresentation, clock: @escaping LocalMediaOwnership.Clock) {
    self.platform = platform; self.clock = clock
  }

  var hasOwner: Bool { owner.hasOwner }
  var isDrained: Bool { !owner.hasOwner && pending == nil && releasing == nil }
  var snapshot: LocalMediaOwnership.Claim? { owner.snapshot }

  static func validLabel(_ text: String) -> Bool {
    !text.isEmpty && text.utf16.count <= 256 && !text.utf16.contains(0) &&
      !text.utf16.allSatisfy { $0 <= 32 }
  }

  func binding(token: String, account: String) -> Key? {
    owner.binding(token: token, account: account)
  }

  /// A recorder cannot adopt the monitor's disclosure, a retired session or a
  /// different recording nonce. Foreground is needed for acquisition only.
  func permitsRecording(_ key: Key, nonce: String, acquiring: Bool) -> Bool {
    guard !closing, !detached, (!acquiring || pending == nil), releasing == nil,
          recordingBody != nil, owner.current(key),
          let value = owner.snapshot, value.key === key,
          value.role == .listener, value.active, value.presented,
          value.recording == nonce else { return false }
    if acquiring && !platform.foreground { return false }
    return owner.current(key) && owner.ownsRecording(key, nonce: nonce)
  }

  private func render(_ key: Key, recording: Bool = true) -> LocalMediaView? {
    guard owner.matches(key), let base else { return nil }
    let body = recording ? recordingBody ?? base.body : base.body
    return base.with(body: owner.snapshot?.retired == true ?
      (recordingBody != nil && recording ? body + " — " + base.stopping : base.stopping) : body)
  }

  // No work queue: concurrent capture/recording/state calls fail closed. Only
  // release may join the current confirmation, so cleanup cannot race a late post.
  private func operation(_ body: @escaping @MainActor () async -> Bool) async -> Bool {
    guard pending == nil, releasing == nil, !detached else { return false }
    pendingID += 1
    let id = pendingID
    let task = Task { @MainActor in await body() }
    pending = task
    let result = await task.value
    if pendingID == id { pending = nil }
    return result
  }

  func present(token: String, account: String, role: LocalMediaOwnership.Role,
    normalMode: Bool, title: String, body: String, stop: String, stopping: String,
    rightToLeft: Bool) async -> Bool {
    guard !detached, !closing, !owner.hasOwner, pending == nil, releasing == nil,
          normalMode, [title, body, stop, stopping].allSatisfy(Self.validLabel) else { return false }
    self.normalMode = normalMode
    guard let key = owner.reserve(token: token, account: account, role: role) else { return false }
    let view = LocalMediaView(key: key, title: title, body: body, stop: stop,
      stopping: stopping, rightToLeft: rightToLeft)
    base = view
    let shown = await operation { [self] in
      await platform.present(view, stop: { [weak self] in self?.requestStop(key) })
    }
    guard shown, !detached, releasing == nil, owner.confirmPresentation(key) else {
      retire(key); return false
    }
    return true
  }

  private func confirmed(_ key: Key) async -> Bool {
    guard owner.matches(key), owner.snapshot?.presented == true, owner.current(key) else {
      retire(key); return false
    }
    let exists = await operation { [self] in await platform.exists(key) }
    guard exists, !detached, releasing == nil, owner.current(key) else {
      retire(key); return false
    }
    return true
  }

  func capture(_ key: Key) async -> Bool {
    guard await confirmed(key) else { return false }
    return owner.reserveCapture(key)
  }

  func active(_ key: Key) async -> Bool {
    guard await confirmed(key) else { return false }
    return owner.activate(key)
  }

  func state(_ key: Key) async -> Bool {
    // The existing five-second health tick may overlap a slow OS update. It
    // observes the already-confirmed purpose; it grants no capture/OUTPUT or
    // new recording acknowledgement. The update still checks its own readback
    // and retires the purpose on failure. Do not treat local UI work as loss.
    if pending != nil && releasing == nil && !detached &&
        owner.snapshot?.presented == true && owner.current(key) { return true }
    return await confirmed(key)
  }

  func showRecording(_ key: Key, nonce: String, body: String) async -> Bool {
    guard Self.validLabel(body), await confirmed(key), owner.reserveRecording(key, nonce: nonce) else {
      return false
    }
    // A partial OS publication stays owned even when its callback reports failure.
    recordingBody = body
    guard let view = render(key) else { return false }
    let shown = await operation { [self] in await platform.update(view) }
    guard shown, !detached, releasing == nil, owner.current(key),
          owner.ownsRecording(key, nonce: nonce) else {
      retire(key); return false
    }
    return true
  }

  // Called only after the real OUTPUT has closed. This cleanup remains legal
  // after native Stop, account revocation, backgrounding or eligibility loss.
  func hideRecording(_ key: Key, nonce: String) async -> Bool {
    guard !detached, owner.ownsRecording(key, nonce: nonce),
          let view = render(key, recording: false) else { return false }
    let hidden = await operation { [self] in await platform.withdrawRecording(view) }
    guard hidden, !detached, owner.confirmRecordingReleased(key, nonce: nonce) else { return false }
    recordingBody = nil
    return true
  }

  func requestStop(_ key: Key) {
    guard owner.requestStop(key), notifyingStop !== key, !detached else { return }
    let previous = notifyingStop
    notifyingStop = key
    defer { notifyingStop = previous }
    // Fence only synchronous echoes. A later local gesture must be able to
    // retry an uncertain drain; Dart coalesces its actual SDK stop future.
    onStop?(key) // Immutable object; never a fresh lookup by token/name.
  }

  private func retire(_ key: Key) {
    guard let value = owner.snapshot, value.key === key, !value.retired else { return }
    requestStop(key)
  }

  // False means the caller must keep its window/engine alive until onDrained.
  // Only a confirmed Dart/SDK release may clear the owner; Stop is not an ACK.
  func requestClose() -> Bool {
    closing = true
    if let key = owner.snapshot?.key { requestStop(key) }
    return isDrained
  }

  // A canceled Flutter/AppKit quit may admit a fresh local purpose only after
  // the old one really drained. This never clears retirement on an old key.
  func cancelClose() -> Bool {
    guard !detached, isDrained else { return false }
    closing = false
    return true
  }

  func release(_ key: Key) async -> Bool {
    guard !detached, owner.matches(key) else { return false }
    if let releasing { return await releasing.value }
    // Fence admission before waiting for an outstanding native post/readback.
    _ = owner.requestStop(key)
    let existing = pending
    let existingID = pendingID
    let task = Task { @MainActor [self] in
      if let existing { _ = await existing.value }
      guard owner.matches(key), owner.snapshot?.recording == nil else { return false }
      let removed = await platform.remove(key)
      guard !detached, removed, owner.confirmReleased(key) else { return false }
      base = nil; recordingBody = nil
      return true
    }
    releasing = task
    let removed = await task.value
    releasing = nil
    // A posting caller may not yet have unwound; it can only fail after this
    // release and cannot admit anything while closing. Defer the idle callback
    // until its pending handle has also been joined and cleared.
    if let existing {
      _ = await existing.value
      if pendingID == existingID { pending = nil }
    }
    if closing && isDrained { onDrained?() }
    return removed
  }

  // Used immediately before a normal engine teardown, never to skip a drain.
  func detach() -> Bool {
    guard isDrained else { return false }
    detached = true; closing = true; onStop = nil; onDrained = nil
    return true
  }
}
