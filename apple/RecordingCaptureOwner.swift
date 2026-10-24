import Foundation

/// An original selected receiver wrapper. No implementation may substitute a
/// fresh source during attach or detach, even when its textual ID is equal.
@MainActor protocol RecordingCaptureSource: AnyObject {
  var isCurrent: Bool { get }
  func attach() -> Bool
  func detach() -> Bool
}

/// Construction acquires nothing. start prepares the owned output off the UI
/// actor; seal synchronously refuses new PCM before a renderer is removed.
@MainActor protocol RecordingCaptureWriter: AnyObject {
  func start(prepared: @escaping @MainActor @Sendable (Bool) -> Void,
             closed: @escaping @MainActor @Sendable (RecordingFileClosed) -> Void) -> Bool
  func seal()
}

/// One immutable local acquisition attempt, shared by the actual Apple bridge
/// and its fault tests. It never opens a microphone or authorizes a successor.
@MainActor final class RecordingCaptureOwner {
  enum Stage { case idle, preparing, active, stopping, closed }
  private let permitted: @MainActor () -> Bool
  private let borrow: @MainActor () -> (any RecordingCaptureSource)?
  private let makeWriter: @MainActor (any RecordingCaptureSource) -> (any RecordingCaptureWriter)?
  private var source: (any RecordingCaptureSource)?
  private var writer: (any RecordingCaptureWriter)?
  private var attached = false, attaching = false, detaching = false
  private var retired = false, admitted = false, writerStarted = false
  private var preparationHandled = false, notifying = false
  private var changed: (@MainActor () -> Void)?
  private var closed: RecordingFileClosed?
  private(set) var stage = Stage.idle
  private(set) var failed = false

  init(permitted: @escaping @MainActor () -> Bool,
       borrow: @escaping @MainActor () -> (any RecordingCaptureSource)?,
       writer: @escaping @MainActor (any RecordingCaptureSource) -> (any RecordingCaptureWriter)?,
       changed: @escaping @MainActor () -> Void = {}) {
    self.permitted = permitted; self.borrow = borrow
    makeWriter = writer; self.changed = changed
  }

  var released: Bool {
    admitted && retired && !attached && !attaching && !detaching &&
      (!writerStarted || closed?.released == true)
  }
  var finalized: Bool { released && !failed && closed?.valid == true }
  var bytes: Int { closed?.bytes ?? 0 }

  private var current: Bool {
    guard !retired, permitted(), !retired else { return false }
    return true
  }

  /// True means an attempt was admitted, not that a renderer is attached.
  /// The bridge reports started only after the asynchronous preparation.
  @discardableResult func start() -> Bool {
    guard !admitted, !retired else { return false }
    admitted = true; stage = .preparing
    guard current, let selected = borrow(), current, selected.isCurrent, current else {
      failed = true; stop(); return false
    }
    source = selected
    guard let output = makeWriter(selected), current, selected.isCurrent, current else {
      failed = true; stop(); return false
    }
    writer = output; writerStarted = true
    let accepted = output.start(prepared: { [weak self] ready in
      self?.prepared(ready)
    }, closed: { [weak self] proof in self?.completed(proof) })
    if !accepted {
      // Refused admission never owns output. A writer that acquired resources
      // must return true and eventually supply its own positive close proof.
      writerStarted = false; failed = true; stop()
    } else if retired { stop() }
    return accepted && !retired
  }

  private func prepared(_ ready: Bool) {
    guard !preparationHandled else { return }
    preparationHandled = true
    guard stage == .preparing, !retired, closed == nil else {
      writer?.seal(); return
    }
    guard ready, current, let source, source.isCurrent, current else {
      failed = true; stop(); return
    }
    // attach can synchronously invoke SDK callbacks. Retirement during it must
    // wait for its return before detach or a positive release can be published.
    attaching = true; attached = true
    let didAttach = source.attach()
    attaching = false
    guard didAttach, current, source.isCurrent, current else {
      failed = true; stop(); return
    }
    stage = .active; notify()
  }

  /// Checks are read-only until a source/purpose has become invalid. Neither
  /// State nor a retry may borrow a replacement or restart capture.
  @discardableResult func refresh() -> Bool {
    guard stage == .active, !retired, let source, current,
          source.isCurrent, current else {
      if stage == .active { failed = true; stop() }
      return false
    }
    return true
  }

  func stop() {
    retired = true
    if !admitted { admitted = true }
    if stage != .closed { stage = .stopping }
    writer?.seal() // Fence copies before entering the original SDK wrapper.
    if attached && !attaching && !detaching, let source {
      detaching = true
      let removed = source.detach()
      detaching = false
      if removed { attached = false }
    }
    settle()
  }

  private func completed(_ proof: RecordingFileClosed) {
    // The original writer has one terminal result. An uncertain native close
    // cannot be replaced by a later callback claiming an unrelated FD closed.
    guard closed == nil else { return }
    closed = proof
    if stage != .stopping { failed = true }
    if !proof.valid { failed = true }
    stop()
  }

  private func settle() {
    if released {
      stage = .closed
      source = nil; writer = nil
    }
    notify()
  }

  private func notify() {
    guard !notifying else { return }
    notifying = true; defer { notifying = false }
    changed?()
  }
}
