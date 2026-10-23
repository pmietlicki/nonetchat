import Foundation

@MainActor private final class Gate {
  private var entered = false
  private var observer: CheckedContinuation<Void, Never>?
  private var waiter: CheckedContinuation<Bool, Never>?
  func block() async -> Bool {
    entered = true
    return await withCheckedContinuation { continuation in
      waiter = continuation
      let ready = observer; observer = nil; ready?.resume()
    }
  }
  func ready() async {
    if entered { return }
    await withCheckedContinuation { observer = $0 }
  }
  func finish(_ result: Bool) {
    let completion = waiter; waiter = nil; completion?.resume(returning: result)
  }
}

@MainActor private final class NativeView: LocalMediaPresentation {
  var foreground = true
  var existsResult = true
  var presentResult = true
  var updateResult = true
  var removeResult = true
  var presentGate: Gate?
  var updateGate: Gate?
  var existsGate: Gate?
  var removeGate: Gate?
  var withdrawalStopsPurpose = false
  var views: [LocalMediaView] = []
  var stops: [@MainActor () -> Void] = []
  var removed: [LocalMediaOwnership.Key] = []
  func present(_ view: LocalMediaView, stop: @escaping @MainActor () -> Void) async -> Bool {
    views.append(view); stops.append(stop)
    if let presentGate { return await presentGate.block() }
    return presentResult
  }
  func update(_ view: LocalMediaView) async -> Bool {
    views.append(view)
    if let updateGate { return await updateGate.block() }
    return updateResult
  }
  func withdrawRecording(_ view: LocalMediaView) async -> Bool {
    if withdrawalStopsPurpose {
      let removed = await remove(view.key)
      if removed { stops.last?() }
      return removed
    }
    return await update(view)
  }
  func exists(_ key: LocalMediaOwnership.Key) async -> Bool {
    if let existsGate { return await existsGate.block() }
    return existsResult
  }
  func remove(_ key: LocalMediaOwnership.Key) async -> Bool {
    removed.append(key)
    if let removeGate { return await removeGate.block() }
    return removeResult
  }
}

@MainActor private final class HostFixture {
  let view = NativeView()
  var now = 0.0
  var stops: [LocalMediaOwnership.Key] = []
  var drains = 0
  lazy var host: LocalMediaHost = {
    let host = LocalMediaHost(platform: view, clock: { [weak self] in self?.now ?? .nan })
    host.onStop = { [weak self] in self?.stops.append($0) }
    host.onDrained = { [weak self] in self?.drains += 1 }
    return host
  }()
  func present(role: LocalMediaOwnership.Role = .monitor,
    normal: Bool = true, title: String = "NoNetChat") async -> Bool {
    await host.present(token: HostTests.token, account: "field-account", role: role,
      normalMode: normal, title: title, body: "Microphone actif", stop: "Arrêter",
      stopping: "Arrêt en cours", rightToLeft: true)
  }
}

private enum Failure: Error { case failed(String) }

@main private struct HostTests {
  static let token = "abcdefghijklmnopqrstuvwx"
  static let nonce = "zyxwvutsrqponmlkjihgfedc"
  @MainActor static var checks = 0
  @MainActor static func check(_ value: Bool, _ message: String) throws {
    checks += 1
    if !value { throw Failure.failed(message) }
  }
  @MainActor static func key(_ f: HostFixture) throws -> LocalMediaOwnership.Key {
    guard let key = f.host.binding(token: token, account: "field-account") else {
      throw Failure.failed("missing scoped key")
    }
    return key
  }
  @MainActor static func active(_ f: HostFixture,
    role: LocalMediaOwnership.Role = .monitor) async throws -> LocalMediaOwnership.Key {
    try check(await f.present(role: role), "native presentation confirmed")
    let key = try key(f)
    if role == .monitor { try check(await f.host.capture(key), "capture after actual indication") }
    try check(await f.host.active(key), "active owner confirmed")
    return key
  }

  @MainActor static func admission() async throws {
    let f = HostFixture()
    try check(!(await f.present(normal: false)), "protected admission rejected")
    f.view.foreground = false
    try check(!(await f.present()), "foreground required before UI")
    f.view.foreground = true
    for label in ["", "\n ", "a\0b", String(repeating: "😀", count: 129)] {
      try check(!(await f.present(title: label)), "invalid copy rejected")
    }
    try check(f.view.views.isEmpty && !f.host.hasOwner, "invalid requests touch no native UI")
    let owner = try await active(f)
    try check(f.view.views.last?.rightToLeft == true, "RTL reaches native view")
    try check(!(await f.present()), "purpose cannot be replaced")
    try check(!f.host.detach(), "cannot detach before native media release")
    try check(await f.host.release(owner), "actual cleanup releases purpose")
    try check(f.host.detach(), "drained engine may detach")
    try check(!(await f.present()), "retired engine cannot admit a new purpose")
  }

  @MainActor static func roles() async throws {
    let f = HostFixture(); let owner = try await active(f, role: .listener)
    try check(!(await f.host.capture(owner)), "listener never acquires microphone")
    f.view.foreground = false
    try check(!(await f.host.showRecording(owner, nonce: nonce, body: "Enregistrement")),
      "parent recording needs local foreground gesture")
    try check(await f.host.state(owner), "active listening does not expire in background")
    try check(await f.host.release(owner), "listener cleanup")
    let g = HostFixture(); let monitor = try await active(g)
    g.view.foreground = false; g.now = 1e12
    try check(await g.host.showRecording(monitor, nonce: nonce, body: "Enregistré chez le parent"),
      "remote recording indication is independent of monitor OUTPUT and foreground")
    try check(!(await g.host.release(monitor)), "live recording nonce prevents full release")
    try check(await g.host.hideRecording(monitor, nonce: nonce), "closed OUTPUT can withdraw disclosure")
    try check(await g.host.release(monitor), "monitor cleanup after real OUTPUT closure")
  }

  @MainActor static func latePresentation() async throws {
    let f = HostFixture(); let gate = Gate(); f.view.presentGate = gate
    let presenting = Task { @MainActor in await f.present() }
    await gate.ready()
    let owner = try key(f)
    try check(!f.host.requestClose(), "close waits for posted indication and media drain")
    try check(f.stops.count == 1 && f.stops.first === owner, "one stop binds exact owner")
    let release = Task { @MainActor in await f.host.release(owner) }
    try check(f.view.removed.isEmpty, "cannot remove ahead of pending native post")
    gate.finish(true)
    try check(!(await presenting.value), "late successful post never revives stopped purpose")
    try check(await release.value, "release joins native post before removal")
    try check(f.view.removed.count == 1 && f.host.isDrained, "confirmed cleanup is quiescent")
    try check(f.drains == 1, "one deferred close after actual removal")
    try check(f.host.detach(), "engine teardown safe only after drain")
    f.view.stops.first?()
    try check(f.stops.count == 1, "native callback cannot enter detached engine")
  }

  @MainActor static func failedPresentation() async throws {
    let f = HostFixture(); f.view.presentResult = false
    try check(!(await f.present()), "failed OS confirmation rejects admission")
    let owner = try key(f)
    try check(f.host.hasOwner && f.stops.count == 1, "partial native posting remains owned")
    try check(!(await f.host.capture(owner)), "no capture after uncertain presentation")
    f.view.removeResult = false
    try check(!(await f.host.release(owner)), "unconfirmed removal retains purpose")
    let successor = await f.present()
    try check(f.host.hasOwner && !successor, "successor refused during uncertain cleanup")
    f.view.removeResult = true
    try check(await f.host.release(owner), "same owner may retry native removal")
    try check(f.view.removed.count == 2 && f.host.isDrained, "cleanup retry does not re-present UI")
  }

  @MainActor static func recording() async throws {
    let f = HostFixture(); let owner = try await active(f)
    f.view.updateResult = false
    try check(!(await f.host.showRecording(owner, nonce: nonce, body: "Enregistrement")),
      "failed update never confirms OUTPUT indication")
    try check(f.host.snapshot?.recording == nonce, "uncertain native recording remains owned")
    try check(!(await f.host.hideRecording(owner, nonce: token)), "foreign nonce cannot hide disclosure")
    try check(!(await f.host.hideRecording(owner, nonce: nonce)), "failed withdrawal retains nonce")
    try check(!(await f.host.release(owner)), "release cannot skip uncertain recording")
    f.view.updateResult = true
    try check(await f.host.hideRecording(owner, nonce: nonce), "closed OUTPUT cleanup remains available after Stop")
    try check(f.view.views.last?.body == "Arrêt en cours", "retired UI never returns to active copy")
    try check(await f.host.release(owner), "release after recording removal")
  }

  @MainActor static func lateRecording() async throws {
    let f = HostFixture(); let owner = try await active(f)
    let gate = Gate(); f.view.updateGate = gate
    let update = Task { @MainActor in await f.host.showRecording(owner, nonce: nonce, body: "Enregistrement") }
    await gate.ready()
    f.view.stops.first?()
    gate.finish(true)
    try check(!(await update.value), "late recording confirmation cannot follow native Stop")
    try check(f.host.snapshot?.recording == nonce, "nonce retained until real OUTPUT closes")
    f.view.updateGate = nil
    try check(await f.host.hideRecording(owner, nonce: nonce), "recording drain stays possible")
    try check(await f.host.release(owner), "late update cleaned up")
  }

  @MainActor static func lostRecordingIndication() async throws {
    let f = HostFixture(); let owner = try await active(f)
    try check(await f.host.showRecording(owner, nonce: nonce, body: "Enregistrement"), "recording indication")
    f.view.withdrawalStopsPurpose = true
    f.view.removeResult = false
    try check(!(await f.host.hideRecording(owner, nonce: nonce)), "failed OS removal retains recording nonce")
    try check(f.host.snapshot?.recording == nonce, "uncertain withdrawal stays owned")
    f.view.removeResult = true
    try check(await f.host.hideRecording(owner, nonce: nonce), "confirmed native removal withdraws closed OUTPUT")
    try check(f.stops.count == 1 && f.host.snapshot?.retired == true, "lost disclosure retires purpose")
    try check(!(await f.host.capture(owner)), "cleared disclosure never reopens capture")
    try check(await f.host.release(owner), "retired purpose can finish cleanup without restoring permission")
  }

  @MainActor static func maintenanceDuringUpdate() async throws {
    let f = HostFixture(); let owner = try await active(f)
    let gate = Gate(); f.view.updateGate = gate
    let updating = Task { @MainActor in
      await f.host.showRecording(owner, nonce: nonce, body: "Enregistrement")
    }
    await gate.ready()
    try check(await f.host.state(owner), "health maintenance must not cancel an outstanding native UI update")
    try check(f.stops.isEmpty, "native update and health maintenance do not revoke each other")
    gate.finish(true)
    try check(await updating.value, "original OS recording confirmation remains valid")
    f.view.updateGate = nil
    try check(await f.host.hideRecording(owner, nonce: nonce), "confirmed OUTPUT withdrawal")
    try check(await f.host.release(owner), "maintenance case cleans up")
  }

  @MainActor static func cancelledQuit() async throws {
    let f = HostFixture(); let old = try await active(f)
    try check(!f.host.requestClose(), "quit asks for the old native media drain")
    try check(!f.host.cancelClose(), "cancel cannot revive an undrained owner")
    try check(await f.host.release(old), "old media really closes before cancelable Flutter exit")
    try check(f.host.cancelClose(), "canceled Flutter exit keeps the engine usable")
    let next = try await active(f)
    try check(next !== old, "new local gesture gets a new immutable purpose")
    f.view.stops.first?()
    try check(await f.host.state(next), "old native close cannot stop the new gesture")
    try check(await f.host.release(next), "new purpose closes normally")
    try check(f.host.detach() && !f.host.cancelClose(), "actual engine teardown cannot be canceled")
  }

  @MainActor static func scopes() async throws {
    let a = HostFixture(), b = HostFixture()
    let old = try await active(a), other = try await active(b)
    try check(!(await a.host.release(other)), "foreign native key cannot release this engine")
    a.host.requestStop(other)
    let originalCurrent = await a.host.state(old)
    try check(a.stops.isEmpty && originalCurrent, "foreign Stop cannot retire current engine")
    try check(await a.host.release(old), "old purpose removed")
    let next = try await active(a)
    a.view.stops.first?()
    let nextCurrent = await a.host.state(next)
    try check(a.stops.isEmpty && nextCurrent, "old OS menu closure cannot stop successor")
    try check(!(await a.host.hideRecording(old, nonce: nonce)), "old recording cannot mutate successor")
    try check(await b.host.state(other), "other graph remains independent")
    try check(await a.host.release(next), "next purpose removed")
    try check(await b.host.release(other), "independent graph cleanup")
  }

  @MainActor static func lateStateAndRemoval() async throws {
    let f = HostFixture(); let owner = try await active(f)
    let gate = Gate(); f.view.existsGate = gate
    let state = Task { @MainActor in await f.host.state(owner) }
    await gate.ready()
    try check(!f.host.requestClose(), "close retains engine during OS readback")
    let closing = Task { @MainActor in await f.host.release(owner) }
    gate.finish(true)
    try check(!(await state.value), "old positive readback cannot revoke close")
    try check(await closing.value, "release joins old readback")
    try check(f.drains == 1, "actual quiescence posts one close")
    let g = HostFixture(); let current = try await active(g)
    let removal = Gate(); g.view.removeGate = removal
    let first = Task { @MainActor in await g.host.release(current) }
    await removal.ready()
    let second = Task { @MainActor in await g.host.release(current) }
    try check(!(await g.present()), "pending native removal prevents successor")
    removal.finish(true)
    let firstResult = await first.value, secondResult = await second.value
    try check(firstResult && secondResult, "concurrent releases join one removal")
    try check(g.view.removed.count == 1, "no duplicated OS cleanup")
  }

  @MainActor static func main() async {
    do {
      for (name, body) in [
        ("admission", admission), ("roles", roles), ("late-presentation", latePresentation),
        ("failed-presentation", failedPresentation), ("recording", recording),
        ("late-recording", lateRecording), ("lost-recording-indication", lostRecordingIndication), ("scopes", scopes),
        ("late-state-removal", lateStateAndRemoval), ("maintenance-during-update", maintenanceDuringUpdate),
        ("cancelled-quit", cancelledQuit)
      ] {
        let before = checks
        try await body(); try check(checks > before, "case executes checks")
        print("LOCAL_MEDIA_HOST_CASE_OK:\(name)")
      }
      print("LOCAL_MEDIA_HOST_OK:\(checks)")
    } catch {
      FileHandle.standardError.write(Data("LOCAL_MEDIA_HOST_FAILED:\(error)\n".utf8))
      exit(1)
    }
  }
}
