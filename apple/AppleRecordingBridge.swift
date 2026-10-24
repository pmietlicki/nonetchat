import Foundation
import CoreFoundation
import CryptoKit
#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

/// The local channel belongs to the same engine as its native disclosure and
/// observed WebRTC publication. It never uses the SDK's shared singleton.
@MainActor final class AppleRecordingBridge {
  private struct Binding: Equatable, Sendable {
    let id: Int, token: String, file: String
    let session: String, account: String, recording: String
    var fields: [String: Any] {
      ["version": 2, "recorderId": id, "nonetToken": token, "fileId": file,
       "localMediaToken": session, "localMediaAccount": account,
       "localRecordingToken": recording]
    }
    init?(_ args: [String: Any]) {
      guard let version = Self.integer(args["version"]), version == 2,
            let id = Self.integer(args["recorderId"]), id >= 0, id < Int(Int32.max),
            let token = args["nonetToken"] as? String, LocalMediaOwnership.validToken(token),
            let file = args["fileId"] as? String, LocalMediaOwnership.validToken(file),
            let session = args["localMediaToken"] as? String, LocalMediaOwnership.validToken(session),
            let recording = args["localRecordingToken"] as? String, LocalMediaOwnership.validToken(recording),
            let account = args["localMediaAccount"] as? String, !account.isEmpty,
            account.utf16.count <= 256, !account.utf16.contains(0) else { return nil }
      self.id = id; self.token = token; self.file = file
      self.session = session; self.account = account; self.recording = recording
    }
    private static func integer(_ value: Any?) -> Int? {
      guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
            let result = Int(n.stringValue) else { return nil }
      return result
    }
  }
  @MainActor private final class Slot {
    let binding: Binding
    var owner: RecordingCaptureOwner?
    var directory: ReceivedAudioSources?
    var start: FlutterResult?, stop: FlutterResult?
    init(_ binding: Binding) { self.binding = binding }
    var released: Bool { owner?.released ?? true }
  }
  private struct InspectionBinding: Equatable, Sendable {
    let token: String, file: String
    var fields: [String: Any] { ["version": 1, "requestToken": token, "fileId": file] }
    init?(_ args: [String: Any]) {
      guard let version = args["version"] as? NSNumber,
            CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
            let token = args["requestToken"] as? String, LocalMediaOwnership.validToken(token),
            let file = args["fileId"] as? String, LocalMediaOwnership.validToken(file) else { return nil }
      self.token = token; self.file = file
    }
  }
  @MainActor private final class Inspection {
    let binding: InspectionBinding
    let file: RecordingOutputFile?
    var result: AppleAacInspectionResult?
    var retired = false
    var reply: FlutterResult?, stop: FlutterResult?
    init(_ binding: InspectionBinding, file: RecordingOutputFile? = nil) {
      self.binding = binding; self.file = file
    }
    var released: Bool { file == nil || result?.file.released == true }
  }
  private let channel: FlutterMethodChannel
  private let host: LocalMediaHost
  private let audio: AppleRegisteredAudioSource?
  private let support: @MainActor () throws -> URL
  private var slot: Slot?
  private var inspection: Inspection?
  private let reading = DispatchQueue(label: "fr.pmietlicki.nonetchat.recording-inspection")
  private var calls = 0, closing = false, detached = false
  var onDrained: (@MainActor () -> Void)?

  init(messenger: FlutterBinaryMessenger, host: LocalMediaHost,
       audio: AppleRegisteredAudioSource?,
       support: @escaping @MainActor () throws -> URL = {
         try RecordingBackupPolicy.applicationSupportDirectory()
       }) {
    self.host = host; self.audio = audio; self.support = support
    channel = FlutterMethodChannel(name: "fr.pmietlicki.nonetchat/monitor_recordings",
      binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      Task { @MainActor in
        guard let self, !self.detached else { return }
        self.calls += 1
        self.handle(call) { [self] value in
          result(value)
          self.calls -= 1
          self.drained()
        }
      }
    }
  }

  var isDrained: Bool { calls == 0 && (slot?.released ?? true) && (inspection?.released ?? true) }
  func owns(_ key: LocalMediaHost.Key, nonce: String) -> Bool {
    guard let slot, !slot.released else { return false }
    return slot.binding.session == key.token && slot.binding.account == key.account &&
      slot.binding.recording == nonce
  }

  private func handle(_ call: FlutterMethodCall, reply: @escaping FlutterResult) {
    if call.method == "recordingCapabilities" {
      // This API-v2 implementation includes owned output, callback-only file
      // inspection and the existing scoped Darwin preview. A probe does not
      // acquire a receiver, disclosure, file, permission or microphone.
      reply(!closing && !detached && audio?.isRegistered == true ? 2 : 0); return
    }
    if call.method == "nonetAppleInspectCapabilities" { reply(closing || detached ? 0 : 1); return }
    if call.method == "nonetAppleInspectAudio" || call.method == "nonetAppleInspectStop" {
      guard let args = call.arguments as? [String: Any], let binding = InspectionBinding(args) else {
        reply(FlutterError(code: "UNAVAILABLE", message: "Invalid recording inspection", details: nil)); return
      }
      if call.method == "nonetAppleInspectStop" { stopInspection(binding, reply: reply) }
      else { inspect(args, binding: binding, reply: reply) }
      return
    }
    guard ["recordingStart", "recordingState", "recordingStop"].contains(call.method) else {
      reply(FlutterMethodNotImplemented); return
    }
    guard let args = call.arguments as? [String: Any], let binding = Binding(args) else {
      reply(FlutterError(code: "UNAVAILABLE", message: "Invalid local recording purpose", details: nil)); return
    }
    switch call.method {
    case "recordingStart": start(args, binding: binding, reply: reply)
    case "recordingStop": stop(binding, reply: reply)
    default:
      guard let slot, slot.binding == binding, let owner = slot.owner else {
        failure(reply, binding, released: true); return
      }
      let active = owner.refresh()
      reply(proof(slot, extra: ["active": active, "failed": owner.failed || !active]))
    }
  }

  private func start(_ args: [String: Any], binding: Binding, reply: @escaping FlutterResult) {
    guard !closing, !detached, (inspection?.released ?? true), let audio, audio.isRegistered,
          let key = host.binding(token: binding.session, account: binding.account),
          host.permitsRecording(key, nonce: binding.recording, acquiring: true),
          let peer = args["peerConnectionId"] as? String,
          let receiver = args["receiverId"] as? String,
          let track = args["trackId"] as? String,
          let path = args["path"] as? String else {
      failure(reply, binding, released: true); return
    }
    if let previous = slot {
      guard previous.binding != binding, previous.released else {
        failure(reply, binding, released: previous.binding != binding || previous.released); return
      }
    }
    let selected = Slot(binding)
    slot = selected // Retirement is indexed before any asynchronous preparation.
    selected.start = reply
    let allowed: @MainActor () -> Bool = { [weak self, weak selected, weak key] in
      guard let self, let selected, let key,
            !self.closing, !self.detached, self.slot === selected else { return false }
      return self.host.permitsRecording(key, nonce: binding.recording,
        acquiring: selected.owner?.stage != .active)
    }
    let directory = audio.directory(current: allowed)
    selected.directory = directory
    let owner = RecordingCaptureOwner(permitted: allowed, borrow: {
      guard let source = directory.borrow(peerID: peer, receiverID: receiver, trackID: track) else { return nil }
      return AppleRecordingCaptureSource(selected: source)
    }, writer: { [support] source in
      guard let source = source as? AppleRecordingCaptureSource, source.isCurrent,
            let root = try? support() else { return nil }
      let account = SHA256.hash(data: Data(binding.account.utf8)).map { String(format: "%02x", $0) }.joined()
      let file = RecordingOutputFile(support: root, path: path, accountHash: account, id: binding.file,
        backup: { leaf in
          // Native storage already protected all three levels before reserving
          // its marker. Re-read uncached flags immediately before file creation.
          for value in [leaf, leaf.deletingLastPathComponent(), leaf.deletingLastPathComponent().deletingLastPathComponent()] {
            var directory = value
            directory.removeAllCachedResourceValues()
            guard (try? directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true else { return false }
          }
          return true
        })
      return AppleRecordingCaptureWriter(source: source, file: file)
    }, changed: { [weak self, weak selected] in
      guard let self, let selected else { return }
      self.changed(selected)
    })
    selected.owner = owner
    _ = owner.start()
    changed(selected)
  }

  private func stop(_ binding: Binding, reply: @escaping FlutterResult) {
    guard let selected = slot, selected.binding == binding else {
      if slot?.released ?? true { slot = Slot(binding) }
      reply(binding.fields.merging(["released": true, "finalized": false]) { _, new in new }); return
    }
    guard selected.stop == nil else {
      failure(reply, binding, released: selected.released); return
    }
    selected.stop = reply
    selected.owner?.stop()
    changed(selected)
  }

  private func proof(_ selected: Slot, extra: [String: Any] = [:]) -> [String: Any] {
    selected.binding.fields.merging(["released": selected.released,
      "finalized": selected.owner?.finalized ?? false, "bytes": selected.owner?.bytes ?? 0]) { _, new in new }
      .merging(extra) { _, new in new }
  }

  private func failure(_ reply: FlutterResult, _ binding: Binding, released: Bool) {
    reply(FlutterError(code: "UNAVAILABLE", message: "Local recording unavailable",
      details: binding.fields.merging(["released": released, "finalized": false]) { _, new in new }))
  }

  private func changed(_ selected: Slot) {
    guard slot === selected else { return }
    if let reply = selected.start, selected.owner?.stage == .active {
      selected.start = nil; reply(proof(selected, extra: ["started": true]))
    } else if let reply = selected.start,
              selected.owner?.stage == .stopping || selected.released {
      selected.start = nil; failure(reply, selected.binding, released: selected.released)
    }
    if selected.released {
      selected.directory?.retire(); selected.directory = nil
      if let reply = selected.stop { selected.stop = nil; reply(proof(selected)) }
    }
    drained()
  }

  private func drained() { if closing && isDrained { onDrained?() } }
  func requestClose() -> Bool {
    closing = true
    slot?.owner?.stop()
    inspection?.retired = true
    inspection?.file?.retireReads()
    return isDrained
  }
  func cancelClose() -> Bool {
    guard !detached, isDrained else { return false }
    closing = false; return true
  }
  func detach() -> Bool {
    guard isDrained else { return false }
    detached = true; closing = true
    channel.setMethodCallHandler(nil); onDrained = nil
    return true
  }

  private func inspectionProof(_ job: Inspection) -> [String: Any] {
    job.binding.fields.merging(["released": job.released]) { _, new in new }
  }

  private func inspectionFailure(_ reply: FlutterResult, _ binding: InspectionBinding, released: Bool) {
    reply(FlutterError(code: "UNAVAILABLE", message: "Local recording inspection unavailable",
      details: binding.fields.merging(["released": released]) { _, new in new }))
  }

  private func inspect(_ args: [String: Any], binding: InspectionBinding, reply: @escaping FlutterResult) {
    guard !closing, !detached, (slot?.released ?? true),
          let path = args["path"] as? String, let root = try? support() else {
      inspectionFailure(reply, binding, released: true); return
    }
    if let previous = inspection {
      guard previous.binding != binding, previous.released else {
        inspectionFailure(reply, binding, released: previous.binding != binding || previous.released); return
      }
    }
    let prefix = root.appendingPathComponent("NoNetChatRecordings", isDirectory: true).path + "/"
    guard path.hasPrefix(prefix) else { inspectionFailure(reply, binding, released: true); return }
    let parts = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[1] == binding.file, parts[2] == "audio.m4a" else {
      inspectionFailure(reply, binding, released: true); return
    }
    // Read-only verification does not grant a new writing/backup capability.
    let file = RecordingOutputFile(support: root, path: path, accountHash: String(parts[0]),
      id: binding.file, access: .input, backup: { _ in true })
    let job = Inspection(binding, file: file)
    inspection = job; job.reply = reply
    reading.async {
      let proof = AppleAacInspection.read(file)
      Task { @MainActor [weak self] in self?.inspected(job, result: proof) }
    }
  }

  private func stopInspection(_ binding: InspectionBinding, reply: @escaping FlutterResult) {
    guard let job = inspection, job.binding == binding else {
      if inspection?.released ?? true { inspection = Inspection(binding) }
      reply(binding.fields.merging(["released": true]) { _, new in new }); return
    }
    guard job.stop == nil else { inspectionFailure(reply, binding, released: job.released); return }
    job.retired = true; job.stop = reply; job.file?.retireReads()
    finishInspection(job)
  }

  private func inspected(_ job: Inspection, result: AppleAacInspectionResult) {
    guard inspection === job, job.result == nil else { return }
    job.result = result
    finishInspection(job)
  }

  private func finishInspection(_ job: Inspection) {
    if let result = job.result, let reply = job.reply {
      job.reply = nil
      if !job.retired, result.file.valid, let metadata = result.metadata {
        reply(inspectionProof(job).merging(metadata.fields) { _, new in new })
      } else { inspectionFailure(reply, job.binding, released: job.released) }
    }
    if job.result != nil || job.file == nil, let reply = job.stop {
      job.stop = nil
      if job.released { reply(inspectionProof(job)) }
      else { inspectionFailure(reply, job.binding, released: false) }
    }
    drained()
  }
}
