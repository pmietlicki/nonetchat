import AVFoundation
import UniformTypeIdentifiers

struct RecordingAacResult: Sendable {
  let file: RecordingFileClosed
  let inputRate: Int, inputChannels: Int
  let inputFrames: Int64
}

/// Encoder/file work runs on one private queue. The RTP renderer only copies to
/// pcm. Its owner seals pcm before removing the original renderer. This class
/// never acquires a microphone, a peer, a permission, or a file path from an SDK.
final class RecordingAacWorker: @unchecked Sendable {
  private let file: RecordingOutputFile
  let pcm: RecordingPcmQueue
  private let worker = DispatchQueue(label: "fr.pmietlicki.nonetchat.recording-aac")
  private let lock = NSLock()
  private var started = false
  private var result: RecordingAacResult?
  // The following fields belong exclusively to worker.
  private var lifetime: RecordingAacWorker?
  private var writer: AVAssetWriter?
  private var input: AVAssetWriterInput?
  private var segments: RecordingAacSegments?
  private var pending: RecordingPcmBlock?
  private var rate = 0, channels = 0
  private var frames: Int64 = 0
  private var finishing = false
  private var completed: (@Sendable (RecordingAacResult) -> Void)?

  init(file: RecordingOutputFile, pcm: RecordingPcmQueue) {
    self.file = file; self.pcm = pcm
  }

  /// Preparation is confirmed before the caller may attach its selected track.
  /// A rejected/retired caller must stop; no callback authorizes another source.
  @discardableResult func start(prepared: @escaping @Sendable (Bool) -> Void,
                                closed: @escaping @Sendable (RecordingAacResult) -> Void) -> Bool {
    lock.lock()
    guard !started else { lock.unlock(); return false }
    started = true; lock.unlock()
    worker.async {
      self.lifetime = self; self.completed = closed
      guard self.pcm.state.accepting, self.file.content == .audio, self.file.prepare() else {
        self.pcm.seal(); prepared(false); self.complete(valid: false); return
      }
      guard self.pcm.state.accepting else {
        prepared(false); self.complete(valid: false); return
      }
      prepared(true)
      guard let first = self.pcm.waitTake() else { self.complete(valid: false); return }
      self.pending = first
      self.configure(first)
    }
    return true
  }

  /// Synchronous admission fence; does not wait for a slow codec or disk.
  func stop() { pcm.seal() }

  var closedResult: RecordingAacResult? {
    lock.lock(); defer { lock.unlock() }; return result
  }

  private func configure(_ first: RecordingPcmBlock) {
    guard first.rate > 0, first.rate <= Int(Int32.max), first.channels == 1 || first.channels == 2 else {
      pcm.rejectInvalidInput(); complete(valid: false); return
    }
    rate = first.rate; channels = first.channels
    let sink = RecordingAacSegments(file: file)
    let writer = AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue)!)
    self.writer = writer; segments = sink
    writer.outputFileTypeProfile = .mpeg4AppleHLS
    writer.initialSegmentStartTime = .zero
    // Apple WWDC20/10011, Configure AVAssetWriter 6:28; encoding requires a
    // positive interval. The indefinite/manual mode is passthrough-only.
    writer.preferredOutputSegmentInterval = CMTime(seconds: 6, preferredTimescale: 1)
    writer.delegate = sink // Immutable until writer destruction.
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 20_000]
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
    input.expectsMediaDataInRealTime = true
    self.input = input
    guard writer.canApply(outputSettings: settings, forMediaType: .audio), writer.canAdd(input) else {
      fail(); return
    }
    writer.add(input)
    guard writer.startWriting() else { fail(); return }
    writer.startSession(atSourceTime: .zero)
    // Our owned PCM queue is a pull source. Readiness notifications preserve a
    // pending block during backpressure; no polling or sample dropping.
    input.requestMediaDataWhenReady(on: worker) { [weak self] in self?.pump() }
  }

  private func pump() {
    guard !finishing, let writer, let input else { return }
    guard writer.status == .writing else { fail(); return }
    while input.isReadyForMoreMediaData {
      let block = pending ?? pcm.waitTake()
      pending = nil
      guard let block else { finish(); return }
      guard append(block, to: input) else { fail(); return }
    }
  }

  private func append(_ block: RecordingPcmBlock, to input: AVAssetWriterInput) -> Bool {
    guard block.rate == rate, block.channels == channels, block.frames > 0,
          block.frames <= Int(UInt32.max), frames <= Int64.max - Int64(block.frames),
          let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(rate),
                                     channels: AVAudioChannelCount(channels), interleaved: true),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block.frames)) else { return false }
    buffer.frameLength = AVAudioFrameCount(block.frames)
    let audio = buffer.mutableAudioBufferList.pointee.mBuffers
    guard Int(audio.mDataByteSize) == block.data.count, let destination = audio.mData else { return false }
    block.data.withUnsafeBytes { bytes in
      if let source = bytes.baseAddress { memcpy(destination, source, bytes.count) }
    }
    var description: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription,
      layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
      formatDescriptionOut: &description) == noErr else { return false }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
      presentationTimeStamp: CMTime(value: frames, timescale: CMTimeScale(rate)), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
      makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: block.frames,
      sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
      sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, let sample,
      CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        bufferList: buffer.audioBufferList) == noErr,
      CMSampleBufferSetDataReady(sample) == noErr, input.append(sample) else { return false }
    frames += Int64(block.frames)
    return true
  }

  private func finish() {
    guard !finishing, let writer, let input, writer.status == .writing else { fail(); return }
    finishing = true
    input.markAsFinished()
    writer.finishWriting { [self] in
      worker.async { self.complete(valid: self.writer?.status == .completed && self.pcm.state.failure == .accepted) }
    }
  }

  private func fail() {
    guard !finishing else { return }
    finishing = true; pcm.seal(); pending = nil
    if let writer, writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
    complete(valid: false)
  }

  private func complete(valid: Bool) {
    lock.lock(); let done = result != nil; lock.unlock()
    guard !done else { return }
    pcm.seal(); pending = nil
    let streamValid = segments?.seal() ?? false
    let proof = RecordingAacResult(file: file.finish(finalized: valid && streamValid && frames > 0),
      inputRate: rate, inputChannels: channels, inputFrames: frames)
    // Never set AVAssetWriter.delegate after startWriting; status completed
    // rejects that setter with an Objective-C exception in the real SDK.
    input = nil; writer = nil; segments = nil
    lock.lock(); result = proof; lock.unlock()
    let callback = completed; completed = nil
    callback?(proof)
    if proof.file.released { lifetime = nil }
    // An uncertain FD close remains owned, including across caller retirement.
  }
}

private final class RecordingAacSegments: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private let file: RecordingOutputFile
  private var sealed = false, failed = false, initialization = false, media = false
  init(file: RecordingOutputFile) { self.file = file; super.init() }
  func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData data: Data,
                   segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
    lock.lock(); defer { lock.unlock() }
    guard !sealed else { return } // No SDK callback may touch the retired FD.
    switch segmentType {
    case .initialization:
      if initialization || media { failed = true; return }; initialization = true
    case .separable:
      guard initialization else { failed = true; return }; media = true
    @unknown default: failed = true; return
    }
    if !file.append(data) { failed = true }
  }
  func seal() -> Bool {
    lock.lock(); defer { lock.unlock() }
    sealed = true
    return !failed && initialization && media
  }
}
