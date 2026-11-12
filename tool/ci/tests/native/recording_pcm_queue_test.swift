import Foundation

@main struct RecordingPcmQueueTest {
  final class Checks: @unchecked Sendable {
    private let lock = NSLock()
    private var number = 0
    func check(_ value: Bool) { lock.lock(); number += 1; lock.unlock(); precondition(value) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return number }
  }
  static let checks = Checks()
  static func push(_ queue: RecordingPcmQueue, rate: Int = 16_000,
                   channels: Int = 1, frames: Int = 160, value: Int16 = 37) -> RecordingPcmAdmission {
    let samples = [Int16](repeating: value, count: channels * frames)
    return samples.withUnsafeBytes { queue.push($0.baseAddress, bits: 16, rate: rate, channels: channels, frames: frames) }
  }
  static func main() {
    do {
      let q = RecordingPcmQueue()
      var samples: [Int16] = [1, 2, 3, 4]
      checks.check(samples.withUnsafeBytes { q.push($0.baseAddress, bits: 16, rate: 16_000, channels: 1, frames: 4) } == .accepted)
      samples[0] = 99
      let b = q.waitTake()!
      checks.check(b.rate == 16_000 && b.channels == 1 && b.frames == 4)
      checks.check(b.data == [Int16](1...4).withUnsafeBytes { Data($0) })
      checks.check(q.state.blocks == 0 && q.state.bytes == 0 && q.state.frames == 0)
      q.seal(); checks.check(q.waitTake() == nil)
      print("RECORDING_PCM_CASE_OK:owned-copy")
    }
    do {
      let q = RecordingPcmQueue()
      checks.check(push(q, rate: 48_000, channels: 2) == .accepted)
      _ = q.waitTake()
      checks.check(push(q, rate: 16_000, channels: 2) == .invalid)
      checks.check(push(q, rate: 48_000, channels: 2) == .invalid)
      checks.check(!q.state.accepting && q.state.failure == .invalid)
      checks.check(q.waitTake() == nil)
      print("RECORDING_PCM_CASE_OK:immutable-format")
    }
    do {
      var sample: Int16 = 1
      let invalid: [(Int, Int, Int, Int)] = [(32, 16_000, 1, 1), (16, 0, 1, 1), (16, -1, 1, 1),
        (16, 16_000, 0, 1), (16, 16_000, 3, 1), (16, 16_000, 1, 0), (16, 16_000, 1, -1)]
      for (bits, rate, channels, frames) in invalid {
        let q = RecordingPcmQueue()
        checks.check(q.push(&sample, bits: bits, rate: rate, channels: channels, frames: frames) == .invalid)
        checks.check(q.waitTake() == nil)
      }
      let q = RecordingPcmQueue()
      checks.check(q.push(nil, bits: 16, rate: 16_000, channels: 1, frames: 1) == .invalid)
      print("RECORDING_PCM_CASE_OK:invalid-input")
    }
    do {
      let q = RecordingPcmQueue()
      checks.check(push(q, frames: 16_000) == .accepted)
      checks.check(push(q, frames: 1) == .full)
      checks.check(q.state.frames == 16_000 && q.state.bytes == 32_000)
      checks.check(q.waitTake()?.frames == 16_000)
      checks.check(q.waitTake() == nil && q.state.failure == .full)
      checks.check(push(q) == .full)
      print("RECORDING_PCM_CASE_OK:one-second-bound-and-tail")
    }
    do {
      let q = RecordingPcmQueue()
      for _ in 0..<RecordingPcmQueue.maxBlocks { checks.check(push(q, frames: 1) == .accepted) }
      checks.check(push(q, frames: 1) == .full)
      for _ in 0..<RecordingPcmQueue.maxBlocks { checks.check(q.waitTake()?.frames == 1) }
      checks.check(q.waitTake() == nil && q.state.blocks == 0)
      print("RECORDING_PCM_CASE_OK:block-bound")
    }
    do {
      let q = RecordingPcmQueue()
      checks.check(push(q, rate: 10_000_000, channels: 2, frames: RecordingPcmQueue.maxBytes / 4) == .accepted)
      checks.check(push(q, rate: 10_000_000, channels: 2, frames: 1) == .full)
      checks.check(q.state.bytes == RecordingPcmQueue.maxBytes)
      checks.check(q.waitTake()?.data.count == RecordingPcmQueue.maxBytes)
      checks.check(q.waitTake() == nil)
      print("RECORDING_PCM_CASE_OK:byte-bound")
    }
    do {
      let q = RecordingPcmQueue(copy: { _, _ in preconditionFailure("Overflow reached borrowed memory") })
      var sample: Int16 = 0
      checks.check(q.push(&sample, bits: 16, rate: Int.max, channels: 2, frames: Int.max) == .full)
      checks.check(q.state.bytes == 0 && q.waitTake() == nil)
      print("RECORDING_PCM_CASE_OK:overflow-before-copy")
    }
    do {
      let q = RecordingPcmQueue(copy: { _, _ in nil })
      checks.check(push(q) == .allocationFailed)
      checks.check(!q.state.accepting && q.state.blocks == 0 && q.waitTake() == nil)
      let short = RecordingPcmQueue(copy: { _, _ in Data([1]) })
      checks.check(push(short) == .allocationFailed && short.waitTake() == nil)
      print("RECORDING_PCM_CASE_OK:copy-failure")
    }
    do {
      let q = RecordingPcmQueue()
      for n in 0..<1000 {
        checks.check(push(q, frames: 1, value: Int16(n)) == .accepted)
        checks.check(q.waitTake()?.data == withUnsafeBytes(of: Int16(n)) { Data($0) })
      }
      q.seal(); q.seal()
      checks.check(push(q) == .retired && q.waitTake() == nil && q.state.failure == .accepted)
      print("RECORDING_PCM_CASE_OK:ring-wrap-and-retirement")
    }
    do {
      let q = RecordingPcmQueue()
      let ready = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
      DispatchQueue.global().async {
        ready.signal(); checks.check(q.waitTake() == nil); done.signal()
      }
      checks.check(ready.wait(timeout: .now() + 2) == .success)
      q.seal(); checks.check(done.wait(timeout: .now() + 2) == .success)
      print("RECORDING_PCM_CASE_OK:seal-wakes-worker")
    }
    do {
      let q = RecordingPcmQueue()
      let ready = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
      DispatchQueue.global().async {
        ready.signal()
        var total = 0
        while let b = q.waitTake() {
          checks.check(b.data == withUnsafeBytes(of: Int16(total)) { Data($0) }); total += 1
        }
        checks.check(total == 180); done.signal()
      }
      checks.check(ready.wait(timeout: .now() + 2) == .success)
      for n in 0..<180 { checks.check(push(q, frames: 1, value: Int16(n)) == .accepted) }
      q.seal(); checks.check(done.wait(timeout: .now() + 2) == .success)
      checks.check(q.state.blocks == 0 && q.state.bytes == 0 && q.state.frames == 0)
      print("RECORDING_PCM_CASE_OK:concurrent-drain")
    }
    do {
      let first = RecordingPcmQueue(), second = RecordingPcmQueue()
      checks.check(push(first) == .accepted && push(second) == .accepted)
      first.seal(); checks.check(push(first) == .retired && push(second) == .accepted)
      second.seal(); checks.check(first.waitTake() != nil && first.waitTake() == nil)
      checks.check(second.waitTake() != nil && second.waitTake() != nil && second.waitTake() == nil)
      print("RECORDING_PCM_CASE_OK:independent-owners")
    }
    do {
      let bad = RecordingPcmQueue()
      checks.check(push(bad) == .accepted)
      bad.rejectInvalidInput()
      checks.check(bad.state.failure == .invalid && bad.waitTake() != nil && bad.waitTake() == nil)
      let retired = RecordingPcmQueue()
      retired.seal(); retired.rejectInvalidInput()
      checks.check(retired.state.failure == .accepted && !retired.state.accepting)
      print("RECORDING_PCM_CASE_OK:invalid-format-after-retirement")
    }
    print("RECORDING_PCM_OK:\(checks.count)")
  }
}
