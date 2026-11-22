import Foundation

enum RecordingPcmAdmission: Equatable, Sendable {
  case accepted, retired, invalid, full, allocationFailed
}

struct RecordingPcmBlock: Sendable {
  let rate: Int, channels: Int, frames: Int
  let data: Data
}

struct RecordingPcmState: Equatable, Sendable {
  let accepting: Bool
  let failure: RecordingPcmAdmission
  let blocks: Int, bytes: Int, frames: Int
}

/// Same policy as native/local_pcm_queue.h and GStreamer queue defaults:
/// 200 blocks, 10 MiB, or one second at the immutable input rate. Overflow is
/// terminal and visible: never wait for capacity or silently drop samples in
/// WebRTC's renderer. Only the worker calls waitTake(), and drains after seal.
final class RecordingPcmQueue: @unchecked Sendable {
  static let maxBlocks = 200, maxBytes = 10 * 1024 * 1024
  typealias Copy = @Sendable (UnsafeRawPointer, Int) -> Data?
  private let condition = NSCondition()
  private let copy: Copy
  private var ring = [RecordingPcmBlock?](repeating: nil, count: maxBlocks)
  private var head = 0, blocks = 0, bytes = 0, frames = 0
  private var rate = 0, channels = 0
  private var accepting = true
  private var failure = RecordingPcmAdmission.accepted

  init(copy: @escaping Copy = { source, size in
    guard let memory = malloc(size) else { return nil }
    memcpy(memory, source, size)
    return Data(bytesNoCopy: memory, count: size, deallocator: .free)
  }) { self.copy = copy }

  func push(_ pcm: UnsafeRawPointer?, bits: Int, rate: Int,
            channels: Int, frames: Int) -> RecordingPcmAdmission {
    condition.lock(); defer { condition.unlock() }
    guard accepting else { return failure == .accepted ? .retired : failure }
    guard let pcm, bits == 16, rate > 0, channels == 1 || channels == 2, frames > 0 else {
      return fail(.invalid)
    }
    guard self.rate == 0 || (self.rate == rate && self.channels == channels) else { return fail(.invalid) }
    // Bound before multiplication and before reading any borrowed SDK memory.
    guard frames <= Self.maxBytes / (channels * MemoryLayout<Int16>.size) else { return fail(.full) }
    let size = frames * channels * MemoryLayout<Int16>.size
    guard blocks < Self.maxBlocks, size <= Self.maxBytes - bytes,
          self.frames <= rate, frames <= rate - self.frames else { return fail(.full) }
    guard let data = copy(pcm, size), data.count == size else { return fail(.allocationFailed) }
    ring[(head + blocks) % Self.maxBlocks] = RecordingPcmBlock(rate: rate, channels: channels, frames: frames, data: data)
    blocks += 1; bytes += size; self.frames += frames
    self.rate = rate; self.channels = channels
    condition.signal()
    return .accepted
  }

  /// A dedicated codec worker may block here; a renderer must never call it.
  func waitTake() -> RecordingPcmBlock? {
    condition.lock(); defer { condition.unlock() }
    while blocks == 0 && accepting { condition.wait() }
    guard blocks > 0, let block = ring[head] else { return nil }
    ring[head] = nil; head = (head + 1) % Self.maxBlocks
    blocks -= 1; bytes -= block.data.count; frames -= block.frames
    return block
  }

  func seal() {
    condition.lock(); defer { condition.unlock() }
    accepting = false; condition.broadcast()
  }

  func rejectInvalidInput() {
    condition.lock(); defer { condition.unlock() }
    if accepting { _ = fail(.invalid) }
  }

  var state: RecordingPcmState {
    condition.lock(); defer { condition.unlock() }
    return RecordingPcmState(accepting: accepting, failure: failure,
                             blocks: blocks, bytes: bytes, frames: frames)
  }

  /// condition must be held. Even failure preserves every previously copied tail.
  private func fail(_ reason: RecordingPcmAdmission) -> RecordingPcmAdmission {
    if failure == .accepted { failure = reason }
    accepting = false; condition.broadcast()
    return failure
  }
}
