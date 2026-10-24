import AVFoundation
import CryptoKit
import WebRTC

@main struct AppleRecordingAacTest {
  final class Checks: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    func check(_ value: Bool) { lock.lock(); total += 1; lock.unlock(); precondition(value, "Apple recording check failed") }
    var count: Int { lock.lock(); defer { lock.unlock() }; return total }
  }
  static let checks = Checks()
  final class Fixture: @unchecked Sendable {
    let root: URL, path: URL
    let file: RecordingOutputFile
    let queue = RecordingPcmQueue()
    let renderer: AppleRecordingRenderer
    let worker: RecordingAacWorker
    init(content: RecordingFileContent = .audio, calls: RecordingOutputFile.Calls = .init()) throws {
      let account = String(repeating: "a", count: 64), uid = String(repeating: "b", count: 24)
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
      let leaf = root.appendingPathComponent("NoNetChatRecordings/\(account)/\(uid)", isDirectory: true)
      path = leaf.appendingPathComponent(content.filename)
      try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
      try Data("{\"version\":1,\"account\":\"\(account)\",\"id\":\"\(uid)\",\"binding\":\"\(String(repeating: "c", count: 64))\"}".utf8)
        .write(to: leaf.appendingPathComponent(".owner"))
      file = RecordingOutputFile(support: root, path: path.path, accountHash: account,
        id: uid, content: content, backup: { _ in true }, calls: calls)
      renderer = AppleRecordingRenderer(queue: queue)
      worker = RecordingAacWorker(file: file, pcm: queue)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func capture(_ produce: @escaping @Sendable (AppleRecordingRenderer) -> Void) async -> RecordingAacResult {
      let result = await withCheckedContinuation { continuation in
        checks.check(worker.start(prepared: { [self] accepted in
          if accepted { produce(renderer) }
          worker.stop(); worker.stop()
        }, closed: { continuation.resume(returning: $0) }))
        checks.check(!worker.start(prepared: { _ in preconditionFailure("Duplicate preparation") },
                                  closed: { _ in preconditionFailure("Duplicate close") }))
      }
      checks.check(worker.closedResult?.file == result.file)
      return result
    }
  }

  static func tone(_ renderer: AppleRecordingRenderer, rate: Int, channels: Int, blocks: Int) {
    let frames = rate / blocks
    precondition(frames * blocks == rate)
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(rate),
                               channels: AVAudioChannelCount(channels), interleaved: true)!
    for block in 0..<blocks {
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
      buffer.frameLength = AVAudioFrameCount(frames)
      let pcm = buffer.int16ChannelData!.pointee
      for frame in 0..<frames {
        let value = Int16(sin(Double(block * frames + frame) * 2 * Double.pi * 440 / Double(rate)) * Double(Int16.max) / 8)
        for channel in 0..<channels { pcm[frame * channels + channel] = value }
      }
      renderer.render(pcmBuffer: buffer)
    }
  }

  static func inspect(_ fixture: Fixture, expectedFrames: Int) async throws {
    let data = try Data(contentsOf: fixture.path)
    let asset = AVURLAsset(url: fixture.path)
    let duration = try await asset.load(.duration)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    checks.check(tracks.count == 1 && duration.seconds.isFinite && duration.seconds >= 1)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
    checks.check(reader.canAdd(output)); reader.add(output); checks.check(reader.startReading())
    var frames = 0, first = Double.nan, second = Double.nan, end = Double.nan
    while let sample = output.copyNextSampleBuffer() {
      let stamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
      if first.isNaN { first = stamp } else if second.isNaN { second = stamp }
      end = stamp
      frames += CMSampleBufferGetNumSamples(sample)
    }
    checks.check(reader.status == .completed && frames >= expectedFrames)
    checks.check(first.isFinite && second > first && end >= second)
    let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    print("APPLE_RECORDING_AAC_MEDIA:bytes=\(data.count),duration=\(duration.seconds),frames=\(frames),first=\(first),second=\(second),end=\(end),sha256=\(sha)")
  }

  static func main() async throws {
    for (rate, channels, blocks, label) in [(16_000, 1, 1, "mono-16k"), (48_000, 1, 100, "mono-48k-blocks"),
                                           (48_000, 2, 100, "stereo-48k-blocks"), (44_100, 2, 100, "stereo-44100-blocks")] {
      let fixture = try Fixture()
      let result = await fixture.capture { tone($0, rate: rate, channels: channels, blocks: blocks) }
      checks.check(result.file.released && result.file.valid && result.file.bytes > 0)
      checks.check(result.inputFrames == rate && result.inputRate == rate && result.inputChannels == channels)
      try await inspect(fixture, expectedFrames: 16_000)
      // A callback after drain cannot alter the positive close or its bytes.
      let saved = try Data(contentsOf: fixture.path)
      tone(fixture.renderer, rate: rate, channels: channels, blocks: 1)
      checks.check(try Data(contentsOf: fixture.path) == saved)
      print("APPLE_RECORDING_AAC_CASE_OK:\(label)")
    }
    do {
      let fixture = try Fixture()
      let result = await fixture.capture { _ in }
      checks.check(result.file.released && !result.file.valid && result.file.bytes == 0)
      print("APPLE_RECORDING_AAC_CASE_OK:no-input")
    }
    do {
      let fixture = try Fixture()
      fixture.worker.stop()
      let result = await fixture.capture { _ in preconditionFailure("Retired source admitted") }
      checks.check(result.file.released && !result.file.valid && !FileManager.default.fileExists(atPath: fixture.path.path))
      print("APPLE_RECORDING_AAC_CASE_OK:stop-before-start")
    }
    do {
      let fixture = try Fixture(content: .audioVideo)
      let result = await fixture.capture { _ in preconditionFailure("Wrong media type admitted") }
      checks.check(result.file.released && !result.file.valid && !FileManager.default.fileExists(atPath: fixture.path.path))
      print("APPLE_RECORDING_AAC_CASE_OK:wrong-media-type")
    }
    do {
      var calls = RecordingOutputFile.Calls()
      calls.sync = { _ in errno = EIO; return -1 }
      let fixture = try Fixture(calls: calls)
      let result = await fixture.capture { tone($0, rate: 16_000, channels: 1, blocks: 100) }
      checks.check(result.file.released && !result.file.valid && result.file.bytes > 0)
      print("APPLE_RECORDING_AAC_CASE_OK:sync-failure")
    }
    do {
      var calls = RecordingOutputFile.Calls()
      calls.write = { _, _, _ in errno = EIO; return -1 }
      let fixture = try Fixture(calls: calls)
      let result = await fixture.capture { tone($0, rate: 16_000, channels: 1, blocks: 100) }
      checks.check(result.file.released && !result.file.valid && result.file.bytes == 0)
      print("APPLE_RECORDING_AAC_CASE_OK:write-failure")
    }
    print("APPLE_RECORDING_AAC_OK:\(checks.count)")
  }
}
