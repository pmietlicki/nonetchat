import AVFoundation
import CryptoKit
import WebRTC

@main struct AppleRecordingAacTest {
  final class Checks: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    func check(_ value: Bool, file: StaticString = #fileID, line: UInt = #line) {
      lock.lock(); total += 1; lock.unlock()
      if !value {
        fputs("Apple recording check failed at \(file):\(line)\n", stderr)
        fflush(stdout); fflush(stderr); exit(1)
      }
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return total }
  }
  static let checks = Checks()
  final class Fixture: @unchecked Sendable {
    let root: URL, path: URL
    let file: RecordingOutputFile
    let queue = RecordingPcmQueue()
    let renderer: AppleRecordingRenderer
    let worker: RecordingAacWorker
    init(content: RecordingFileContent = .audio, calls: RecordingOutputFile.Calls = .init(),
         traceSegments: Bool = false) throws {
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
      let traceID = UUID().uuidString
      let trace: (@Sendable (Bool, Data) -> Void)?
      if traceSegments {
        trace = { (initialization: Bool, data: Data) -> Void in
          let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
          print("APPLE_RECORDING_AAC_SEGMENT:fixture=\(traceID),init=\(initialization),bytes=\(data.count),sha256=\(sha)")
          fflush(stdout)
        }
      } else { trace = nil }
      worker = RecordingAacWorker(file: file, pcm: queue, segmentTrace: trace)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func capture(asynchronousProducer: Bool = false,
                 _ produce: @escaping @Sendable (AppleRecordingRenderer) -> Void) async -> RecordingAacResult {
      let result = await withCheckedContinuation { continuation in
        checks.check(worker.start(prepared: { [self] accepted in
          if accepted && asynchronousProducer {
            DispatchQueue.global().async { [self] in
              produce(renderer); worker.stop(); worker.stop()
            }
          } else {
            if accepted { produce(renderer) }
            worker.stop(); worker.stop()
          }
        }, closed: { continuation.resume(returning: $0) }))
        checks.check(!worker.start(prepared: { _ in preconditionFailure("Duplicate preparation") },
                                  closed: { _ in preconditionFailure("Duplicate close") }))
      }
      checks.check(worker.closedResult?.file == result.file)
      print("APPLE_RECORDING_AAC_RESULT:released=\(result.file.released),valid=\(result.file.valid),bytes=\(result.file.bytes),frames=\(result.inputFrames),failure=\(String(describing: result.failure)),sdk=\(String(describing: result.sdkErrorCode)),init=\(result.initializationSegments),media=\(result.mediaSegments)")
      if result.file.released && result.failure == .segments,
         let data = try? Data(contentsOf: path) {
        // Inspect only this fixture's closed synthetic bytes; no logging in the
        // encoder callback, so the production-default path keeps its timing.
        var offset = 0
        while data.count - offset >= 8 {
          var size = data[offset..<offset + 4].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
          let name = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
          var header = 8
          if size == 1 {
            guard data.count - offset >= 16 else { break }
            size = data[offset + 8..<offset + 16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }; header = 16
          }
          if size == 0 { size = UInt64(data.count - offset) }
          guard size >= header, size <= data.count - offset else { break }
          let bytes = data.subdata(in: offset..<offset + Int(size))
          let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
          print("APPLE_RECORDING_AAC_FAILED_BOX:type=\(name),bytes=\(size),sha256=\(sha)")
          offset += Int(size)
        }
      }
      fflush(stdout)
      return result
    }
  }

  static func tone(_ renderer: AppleRecordingRenderer, rate: Int, channels: Int, blocks: Int,
                   seconds: Int = 1, paced: Bool = false) {
    let frames = rate / blocks
    precondition(frames * blocks == rate)
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(rate),
                               channels: AVAudioChannelCount(channels), interleaved: true)!
    for block in 0..<blocks * seconds {
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
      buffer.frameLength = AVAudioFrameCount(frames)
      let pcm = buffer.int16ChannelData!.pointee
      for frame in 0..<frames {
        let value = Int16(sin(Double(block * frames + frame) * 2 * Double.pi * 440 / Double(rate)) * Double(Int16.max) / 8)
        for channel in 0..<channels { pcm[frame * channels + channel] = value }
      }
      renderer.render(pcmBuffer: buffer)
      if paced { Thread.sleep(forTimeInterval: Double(frames) / Double(rate)) }
    }
  }

  static func inspect(_ fixture: Fixture, expectedFrames: Int) async throws {
    let data = try Data(contentsOf: fixture.path)
    let asset = AVURLAsset(url: fixture.path)
    let duration = try await asset.load(.duration)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    checks.check(tracks.count == 1 && duration.seconds.isFinite && duration.seconds >= Double(expectedFrames) / 16_000)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
    checks.check(reader.canAdd(output)); reader.add(output); checks.check(reader.startReading())
    var frames = 0, first = Double.nan, second = Double.nan, end = Double.nan
    while let sample = output.copyNextSampleBuffer() {
      let count = CMSampleBufferGetNumSamples(sample)
      func stamp(_ index: Int) -> Double {
        var timing = CMSampleTimingInfo()
        checks.check(CMSampleBufferGetSampleTimingInfo(sample, at: index, timingInfoOut: &timing) == noErr)
        // A repeated segment may still decode. Its timestamps must belong to
        // this exact continuous sample position, including across buffers.
        checks.check(CMTimeCompare(timing.presentationTimeStamp,
          CMTime(value: Int64(frames + index), timescale: 16_000)) == 0)
        return timing.presentationTimeStamp.seconds
      }
      // AVAssetReader may aggregate the entire PCM output into one buffer.
      // Ask CoreMedia for sample-specific times, never require two buffers.
      if count > 0 {
        if first.isNaN {
          first = stamp(0)
          if count > 1 { second = stamp(1) }
        } else if second.isNaN { second = stamp(0) }
        end = stamp(count - 1)
      }
      frames += count
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
    do {
      let fixture = try Fixture()
      let result = await fixture.capture { renderer in
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                   channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160; renderer.render(pcmBuffer: buffer)
      }
      checks.check(result.file.released && !result.file.valid && result.inputFrames == 0)
      checks.check(fixture.queue.state.failure == .invalid)
      print("APPLE_RECORDING_AAC_CASE_OK:invalid-renderer-format")
    }
    do {
      let fixture = try Fixture()
      let result = await fixture.capture { renderer in
        tone(renderer, rate: 16_000, channels: 1, blocks: 100)
        tone(renderer, rate: 16_000, channels: 1, blocks: 1)
      }
      checks.check(result.file.released && !result.file.valid && result.inputFrames == 16_000)
      checks.check(fixture.queue.state.failure == .full)
      print("APPLE_RECORDING_AAC_CASE_OK:queue-overrun")
    }
    do {
      let fixture = try Fixture()
      let sentinel = Data("Unrelated existing file".utf8)
      try sentinel.write(to: fixture.path)
      let result = await fixture.capture { _ in preconditionFailure("Existing file admitted") }
      checks.check(result.file.released && !result.file.valid && result.inputFrames == 0)
      checks.check(try Data(contentsOf: fixture.path) == sentinel)
      print("APPLE_RECORDING_AAC_CASE_OK:existing-output")
    }
    do {
      for _ in 0..<64 {
        let first = try Fixture(), second = try Fixture()
        async let a = first.capture { tone($0, rate: 16_000, channels: 1, blocks: 100) }
        async let b = second.capture { tone($0, rate: 48_000, channels: 2, blocks: 100) }
        let (one, two) = await (a, b)
        checks.check(one.file.released && one.file.valid && two.file.released && two.file.valid)
        checks.check(one.inputFrames == 16_000 && two.inputFrames == 48_000)
        try await inspect(first, expectedFrames: 16_000)
        try await inspect(second, expectedFrames: 16_000)
      }
      print("APPLE_RECORDING_AAC_CASE_OK:independent-workers")
    }
    do {
      // Exercise repeated cold ownership/finalization, not just a warmed writer.
      for _ in 0..<64 {
        let fixture = try Fixture()
        let result = await fixture.capture { tone($0, rate: 16_000, channels: 1, blocks: 100) }
        checks.check(result.file.released && result.file.valid && result.inputFrames == 16_000)
        try await inspect(fixture, expectedFrames: 16_000)
      }
      print("APPLE_RECORDING_AAC_CASE_OK:repeated-finalization")
    }
    do {
      let fixture = try Fixture()
      // Cross the cited six-second writer interval by the existing one-second
      // queue lifetime, feeding on a separate producer as real RTP does.
      let result = await fixture.capture(asynchronousProducer: true) {
        tone($0, rate: 48_000, channels: 2, blocks: 100, seconds: 7, paced: true)
      }
      checks.check(result.file.released && result.file.valid && result.inputFrames == 48_000 * 7)
      checks.check(result.initializationSegments == 1 && result.mediaSegments >= 2)
      try await inspect(fixture, expectedFrames: 16_000 * 7)
      print("APPLE_RECORDING_AAC_CASE_OK:live-multiple-segments")
    }
    print("APPLE_RECORDING_AAC_OK:\(checks.count)")
  }
}
