import AVFoundation
import UniformTypeIdentifiers

enum RecordingAacFailure: String, Sendable {
  case preparation, retired, noInput, inputFormat, settings, writerStart, append, writerFinish, pcm, segments, file
}

struct RecordingAacResult: Sendable {
  let file: RecordingFileClosed
  let inputRate: Int, inputChannels: Int
  let inputFrames: Int64
  let failure: RecordingAacFailure?
  let sdkErrorCode: Int?
  let initializationSegments: Int, mediaSegments: Int
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
  private var failure: RecordingAacFailure?
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
        self.failure = .preparation
        self.pcm.seal(); prepared(false); self.complete(valid: false); return
      }
      guard self.pcm.state.accepting else {
        self.failure = .retired
        prepared(false); self.complete(valid: false); return
      }
      prepared(true)
      guard let first = self.pcm.waitTake() else {
        self.failure = .noInput; self.complete(valid: false); return
      }
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
      failure = .inputFormat; pcm.rejectInvalidInput(); complete(valid: false); return
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
      fail(.settings); return
    }
    writer.add(input)
    guard writer.startWriting() else { fail(.writerStart); return }
    writer.startSession(atSourceTime: .zero)
    // Our owned PCM queue is a pull source. Readiness notifications preserve a
    // pending block during backpressure; no polling or sample dropping.
    input.requestMediaDataWhenReady(on: worker) { [weak self] in self?.pump() }
  }

  private func pump() {
    guard !finishing, let writer, let input else { return }
    guard writer.status == .writing else { fail(.writerFinish); return }
    while input.isReadyForMoreMediaData {
      let block = pending ?? pcm.waitTake()
      pending = nil
      guard let block else { finish(); return }
      guard append(block, to: input) else { fail(.append); return }
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
    guard !finishing, let writer, let input, writer.status == .writing else { fail(.writerFinish); return }
    finishing = true
    input.markAsFinished()
    writer.finishWriting { [self] in
      worker.async {
        if self.writer?.status != .completed { self.failure = .writerFinish }
        else if self.pcm.state.failure != .accepted { self.failure = .pcm }
        self.complete(valid: self.failure == nil)
      }
    }
  }

  private func fail(_ reason: RecordingAacFailure) {
    guard !finishing else { return }
    finishing = true; failure = reason; pcm.seal(); pending = nil
    if let writer, writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
    complete(valid: false)
  }

  private func complete(valid: Bool) {
    lock.lock(); let done = result != nil; lock.unlock()
    guard !done else { return }
    pcm.seal(); pending = nil
    let stream = segments?.seal() ?? (valid: false, initializations: 0, media: 0)
    if failure == nil && !stream.valid { failure = .segments }
    let closed = file.finish(finalized: valid && stream.valid && frames > 0)
    if failure == nil && !closed.valid { failure = .file }
    let proof = RecordingAacResult(file: closed, inputRate: rate, inputChannels: channels,
      inputFrames: frames, failure: failure, sdkErrorCode: (writer?.error as NSError?)?.code,
      initializationSegments: stream.initializations, mediaSegments: stream.media)
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
  private var initializations = 0, mediaCount = 0
  init(file: RecordingOutputFile) { self.file = file; super.init() }
  func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData data: Data,
                   segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
    lock.lock(); defer { lock.unlock() }
    guard !sealed else { return } // No SDK callback may touch the retired FD.
    switch segmentType {
    case .initialization:
      if initializations < Int.max { initializations += 1 } else { failed = true; return }
      if initialization || media { failed = true; return }; initialization = true
    case .separable:
      if mediaCount < Int.max { mediaCount += 1 } else { failed = true; return }
      guard initialization else { failed = true; return }; media = true
    @unknown default: failed = true; return
    }
    if !file.append(data) { failed = true }
  }
  func seal() -> (valid: Bool, initializations: Int, media: Int) {
    lock.lock(); defer { lock.unlock() }
    sealed = true
    return (!failed && initialization && media, initializations, mediaCount)
  }
}
