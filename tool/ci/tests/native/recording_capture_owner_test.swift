import Foundation

@main struct RecordingCaptureOwnerTest {
  @MainActor final class Checks {
    var count = 0
    func check(_ value: @autoclosure () -> Bool, line: UInt = #line) {
      count += 1
      if !value() { fatalError("Recording capture check failed at \(line)") }
    }
  }
  @MainActor final class Source: RecordingCaptureSource {
    var live = true, attached = false, removable = true
    var attachResult = true
    var attaches = 0, detaches = 0
    var duringAttach: (() -> Void)?
    var duringDetach: (() -> Void)?
    var isCurrent: Bool { live }
    func attach() -> Bool {
      attaches += 1; attached = true; duringAttach?(); return attachResult
    }
    func detach() -> Bool {
      detaches += 1; duringDetach?()
      if removable { attached = false }
      return removable
    }
  }
  @MainActor final class Writer: RecordingCaptureWriter {
    var accepts = true, starts = 0, seals = 0
    var prepared: (@MainActor @Sendable (Bool) -> Void)?
    var closed: (@MainActor @Sendable (RecordingFileClosed) -> Void)?
    var duringStart: (() -> Void)?
    func start(prepared: @escaping @MainActor @Sendable (Bool) -> Void,
               closed: @escaping @MainActor @Sendable (RecordingFileClosed) -> Void) -> Bool {
      starts += 1
      guard accepts else { return false }
      self.prepared = prepared; self.closed = closed; duringStart?(); return true
    }
    func seal() { seals += 1 }
    func complete(released: Bool = true, valid: Bool = true) {
      closed?(RecordingFileClosed(released: released, valid: valid, bytes: 128))
    }
  }
  @MainActor final class Fixture {
    let source = Source(), writer = Writer()
    var allowed = true, borrows = 0, factories = 0
    var availableSource = true, availableWriter = true
    var afterBorrow: (() -> Void)?
    var afterFactory: (() -> Void)?
    lazy var owner = RecordingCaptureOwner(permitted: { [unowned self] in allowed },
      borrow: { [unowned self] in
        borrows += 1; afterBorrow?(); return availableSource ? source : nil
      }, writer: { [unowned self] selected in
        precondition(selected === source)
        factories += 1; afterFactory?(); return availableWriter ? writer : nil
      })
  }

  @MainActor static func main() {
    let c = Checks()
    do {
      let f = Fixture()
      c.check(f.owner.start()); c.check(f.source.attaches == 0)
      c.check(f.owner.stage == .preparing && !f.owner.released)
      f.writer.prepared?(true)
      c.check(f.owner.refresh() && f.source.attaches == 1)
      c.check(!f.owner.start() && f.writer.starts == 1 && f.borrows == 1)
      f.owner.stop()
      c.check(f.source.detaches == 1 && f.writer.seals > 0 && !f.owner.released)
      f.writer.complete()
      c.check(f.owner.released && f.owner.finalized && f.owner.bytes == 128)
      f.owner.stop(); c.check(f.source.detaches == 1)
      print("RECORDING_CAPTURE_CASE_OK:ordered-capture-and-drain")
    }
    do {
      let f = Fixture(); f.allowed = false
      c.check(!f.owner.start() && f.owner.released)
      c.check(f.borrows == 0 && f.factories == 0)
      print("RECORDING_CAPTURE_CASE_OK:ineligible-before-borrow")
    }
    do {
      let f = Fixture(); f.availableSource = false
      c.check(!f.owner.start() && f.factories == 0 && f.owner.released)
      print("RECORDING_CAPTURE_CASE_OK:missing-selected-source")
    }
    do {
      let f = Fixture(); f.afterBorrow = { f.allowed = false }
      c.check(!f.owner.start() && f.factories == 0 && f.owner.released)
      print("RECORDING_CAPTURE_CASE_OK:revoked-during-borrow")
    }
    do {
      let f = Fixture(); f.afterFactory = { f.owner.stop() }
      c.check(!f.owner.start() && f.writer.starts == 0 && f.owner.released)
      print("RECORDING_CAPTURE_CASE_OK:retired-during-construction")
    }
    do {
      let f = Fixture(); f.writer.accepts = false
      c.check(!f.owner.start() && f.owner.released && !f.owner.finalized)
      c.check(f.source.attaches == 0)
      print("RECORDING_CAPTURE_CASE_OK:writer-rejects-admission")
    }
    do {
      let f = Fixture(); c.check(f.owner.start()); f.owner.stop()
      f.writer.prepared?(true)
      c.check(f.source.attaches == 0 && !f.owner.released)
      f.writer.complete(valid: false)
      c.check(f.owner.released && !f.owner.finalized)
      print("RECORDING_CAPTURE_CASE_OK:stop-before-preparation")
    }
    do {
      let f = Fixture(); c.check(f.owner.start())
      f.source.live = false; f.writer.prepared?(true)
      c.check(f.source.attaches == 0 && f.owner.failed)
      f.writer.complete(valid: false); c.check(f.owner.released)
      print("RECORDING_CAPTURE_CASE_OK:source-replaced-during-preparation")
    }
    do {
      let f = Fixture(); c.check(f.owner.start()); f.writer.prepared?(true)
      f.writer.prepared?(true)
      c.check(f.source.attaches == 1 && f.writer.seals == 0 && f.owner.refresh())
      f.owner.stop(); f.writer.complete()
      c.check(f.owner.finalized)
      print("RECORDING_CAPTURE_CASE_OK:duplicate-preparation")
    }
    do {
      let f = Fixture(); f.source.duringAttach = { f.owner.stop() }
      c.check(f.owner.start()); f.writer.prepared?(true)
      c.check(f.source.attaches == 1 && f.source.detaches == 1 && !f.owner.released)
      f.writer.complete(); c.check(f.owner.released && !f.owner.finalized)
      let g = Fixture(); g.source.attachResult = false
      c.check(g.owner.start()); g.writer.prepared?(true)
      c.check(g.source.detaches == 1 && !g.owner.released)
      g.writer.complete(); c.check(g.owner.released && !g.owner.finalized)
      print("RECORDING_CAPTURE_CASE_OK:stop-inside-attachment")
    }
    do {
      let f = Fixture(); c.check(f.owner.start()); f.writer.prepared?(true)
      f.source.live = false
      c.check(!f.owner.refresh() && f.source.detaches == 1)
      f.writer.complete(); c.check(f.owner.released && !f.owner.finalized)
      print("RECORDING_CAPTURE_CASE_OK:terminal-source-loss")
    }
    do {
      let f = Fixture(); c.check(f.owner.start()); f.writer.prepared?(true)
      f.source.removable = false; f.owner.stop(); f.writer.complete()
      c.check(!f.owner.released && f.source.detaches == 2)
      f.source.removable = true; f.owner.stop()
      c.check(f.owner.released && f.source.detaches == 3)
      print("RECORDING_CAPTURE_CASE_OK:retry-original-detachment")
    }
    do {
      let f = Fixture(); c.check(f.owner.start()); f.writer.prepared?(true)
      f.owner.stop(); f.writer.complete(released: false, valid: false)
      f.writer.complete()
      c.check(!f.owner.released && !f.owner.finalized)
      print("RECORDING_CAPTURE_CASE_OK:uncertain-close-is-terminal")
    }
    do {
      let f = Fixture(); c.check(f.owner.start()); f.writer.complete()
      f.writer.prepared?(true)
      c.check(f.owner.released && f.source.attaches == 0 && !f.owner.finalized)
      print("RECORDING_CAPTURE_CASE_OK:completion-before-preparation")
    }
    do {
      let a = Fixture(), b = Fixture()
      c.check(a.owner.start() && b.owner.start())
      a.writer.prepared?(true); b.writer.prepared?(true)
      a.owner.stop(); a.writer.complete()
      c.check(a.owner.released && b.owner.refresh() && b.source.detaches == 0)
      b.owner.stop(); b.writer.complete(); c.check(b.owner.finalized)
      print("RECORDING_CAPTURE_CASE_OK:independent-engine-scopes")
    }
    do {
      let f = Fixture(); f.owner.stop()
      c.check(!f.owner.start() && f.owner.released && f.borrows == 0)
      print("RECORDING_CAPTURE_CASE_OK:retired-before-start")
    }
    print("RECORDING_CAPTURE_OK:\(c.count)")
  }
}
