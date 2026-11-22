import AVFoundation
import WebRTC

/// A renderer is attached only to the exact retained wrapper borrowed before
/// preparing output. Fresh wrappers are used for validation, never for removal.
@MainActor final class AppleRecordingCaptureSource: RecordingCaptureSource {
  let selected: ReceivedAudioSource
  let queue = RecordingPcmQueue()
  private let track: RTCAudioTrack
  private let renderer: AppleRecordingRenderer
  private var attached = false, retired = false

  init?(selected: ReceivedAudioSource) {
    guard selected.isCurrent, let audio = selected.track as? AppleReceivedAudioTrack else { return nil }
    self.selected = selected; track = audio.audio
    renderer = AppleRecordingRenderer(queue: queue)
  }

  var isCurrent: Bool { !retired && selected.isCurrent }

  func attach() -> Bool {
    guard !attached, isCurrent else { return false }
    track.add(renderer)
    attached = true
    return true
  }

  func detach() -> Bool {
    retired = true
    queue.seal()
    if attached {
      // RTCAudioTrack::_adapters is wrapper-local in SDK 73cb8180. Even a
      // removed/replaced source must drain its original renderer here.
      track.remove(renderer)
      attached = false
    }
    selected.retire()
    return true
  }
}

@MainActor final class AppleRecordingCaptureWriter: RecordingCaptureWriter {
  private let worker: RecordingAacWorker
  init(source: AppleRecordingCaptureSource, file: RecordingOutputFile) {
    worker = RecordingAacWorker(file: file, pcm: source.queue)
  }

  func start(prepared: @escaping @MainActor @Sendable (Bool) -> Void,
             closed: @escaping @MainActor @Sendable (RecordingFileClosed) -> Void) -> Bool {
    worker.start(prepared: { ready in
      Task { @MainActor in prepared(ready) }
    }, closed: { result in
      Task { @MainActor in closed(result.file) }
    })
  }

  func seal() { worker.stop() }
}
