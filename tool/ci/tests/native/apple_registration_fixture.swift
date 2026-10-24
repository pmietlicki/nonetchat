#if os(macOS)
import Foundation
import AppKit
import FlutterMacOS
import flutter_webrtc

/// Executed by the disposable demo only. These are real Flutter/SDK objects;
/// no peer factory, SDP, microphone, renderer, output file or RTP is requested.
@MainActor enum AppleRegistrationFixture {
  static var checks = 0
  static func check(_ value: @autoclosure () -> Bool) {
    checks += 1
    precondition(value(), "Apple registration fixture failed")
  }

  static func run(registry: NSObject & FlutterPluginRegistry) -> AppleRegisteredAudioSource {
    let probe = RegistryProbe(base: registry)
    guard let source = AppleWebRTCRegistration.register(in: probe, generated: { proxy in
      let untouched = proxy.registrar(forPlugin: "NoNetRegistrationUntouched")
      check(untouched === probe.untouched)
      let marker = NSObject()
      untouched.publish(marker)
      check(proxy.valuePublished(byPlugin: "NoNetRegistrationUntouched") === marker)
      RegisterGeneratedPlugins(registry: proxy)
    }), let registrar = probe.rtc, let sdk = registrar.delegate as? FlutterWebRTCPlugin else {
      preconditionFailure("Actual generated SDK registration was not observed")
    }
    check(source.isRegistered)
    check(registrar.delegateCalls == 1)
    check(registrar.lastChannel != nil)
    check(registrar.factoryCalls == 1)
    check(sdk.peerConnectionFactory == nil && sdk.peerConnections?.count == 0)
    print("APPLE_REGISTRATION_CASE_OK:actual-generated-registration")

    // Exercise the full public registrar surface on this exact engine. The
    // observed registrar is supplied again by a fake registry below, avoiding
    // duplicate registrations in the real Flutter registry.
    let forwarding = ForwardingRegistry(original: registry, rtc: registrar)
    guard let forwarded = AppleWebRTCRegistration.register(in: forwarding, generated: { proxy in
      let rtc = proxy.registrar(forPlugin: "FlutterWebRTCPlugin")
      check(rtc.messenger === registrar.messenger)
      check(rtc.textures === registrar.textures)
      check(rtc.view === registrar.view)
      check(rtc.viewController === registrar.viewController)
      check(rtc.lookupKey(forAsset: "fixture.txt") == registrar.lookupKey(forAsset: "fixture.txt"))
      check(rtc.lookupKey(forAsset: "fixture.txt", fromPackage: "synthetic") ==
        registrar.lookupKey(forAsset: "fixture.txt", fromPackage: "synthetic"))
      let value = NSObject()
      rtc.publish(value)
      check(registry.valuePublished(byPlugin: "FlutterWebRTCPlugin") === value)
      let channel = FlutterMethodChannel(name: "nonet.fixture.registration", binaryMessenger: rtc.messenger)
      rtc.addMethodCallDelegate(sdk, channel: channel)
      check(registrar.lastChannel === channel && registrar.delegate === sdk)
      let foreign = ForeignPlugin()
      rtc.addMethodCallDelegate(foreign, channel: channel)
      check(registrar.lastChannel === channel && registrar.delegate === foreign)
      let lifecycle = LifecycleProbe()
      rtc.addApplicationDelegate(lifecycle)
      check(registrar.applicationDelegate === lifecycle)
    }) else { preconditionFailure("Forwarding source unavailable") }
    check(forwarded.isRegistered)
    print("APPLE_REGISTRATION_CASE_OK:public-forwarding")

    // The fixture publication can be removed without destroying Flutter. A
    // stale SDK retained by its global slot must not retain our source scope.
    forwarding.witness?.publish(NSNull())
    check(!forwarded.isRegistered)
    check(source.isRegistered)
    print("APPLE_REGISTRATION_CASE_OK:publication-retirement")

    var secondSource: AppleRegisteredAudioSource?
    weak var secondEngine: FlutterEngine?
    autoreleasepool {
      let engine = FlutterEngine(name: "NoNetRegistrationSecond", project: nil,
                                 allowHeadlessExecution: true)
      secondEngine = engine
      defer { engine.shutDownEngine() }
      // Registration before run is sufficient: this second engine never runs
      // Dart, negotiates SDP, constructs a media factory or requests a device.
      let secondProbe = RegistryProbe(base: engine)
      secondSource = AppleWebRTCRegistration.register(in: secondProbe) { proxy in
        FlutterWebRTCPlugin.register(with: proxy.registrar(forPlugin: "FlutterWebRTCPlugin"))
      }
      guard let other = secondProbe.rtc?.delegate as? FlutterWebRTCPlugin else {
        preconditionFailure("Second engine did not register its actual SDK")
      }
      check(other !== sdk)
      check(other.peerConnectionFactory == nil)
      check(secondSource?.isRegistered == true && source.isRegistered)
    }
    check(secondEngine == nil)
    check(secondSource?.isRegistered == false && source.isRegistered)
    print("APPLE_REGISTRATION_CASE_OK:two-real-engines")

    source.retire(); check(!source.isRegistered)
    check(sdk.peerConnectionFactory == nil)
    print("APPLE_REGISTRATION_CASE_OK:explicit-retirement")
    print("APPLE_REGISTRATION_OK:\(checks)")
    fflush(stdout)
    return source
  }
}

@MainActor private final class RegistryProbe: NSObject, @preconcurrency FlutterPluginRegistry {
  let base: NSObject & FlutterPluginRegistry
  var rtc: RegistrarProbe?
  var untouched: FlutterPluginRegistrar?
  init(base: NSObject & FlutterPluginRegistry) { self.base = base }
  func registrar(forPlugin key: String) -> FlutterPluginRegistrar {
    let registrar = base.registrar(forPlugin: key)
    if key == "FlutterWebRTCPlugin" {
      let probe = RegistrarProbe(base: registrar); rtc = probe; return probe
    }
    if key == "NoNetRegistrationUntouched" { untouched = registrar }
    return registrar
  }
  func valuePublished(byPlugin key: String) -> NSObject? { base.valuePublished(byPlugin: key) }
}

@MainActor private final class ForwardingRegistry: NSObject, @preconcurrency FlutterPluginRegistry {
  let original: NSObject & FlutterPluginRegistry
  let rtc: FlutterPluginRegistrar
  var witness: FlutterPluginRegistrar?
  init(original: NSObject & FlutterPluginRegistry, rtc: FlutterPluginRegistrar) {
    self.original = original; self.rtc = rtc
  }
  func registrar(forPlugin key: String) -> FlutterPluginRegistrar {
    if key == "FlutterWebRTCPlugin" { return rtc }
    let registrar = original.registrar(forPlugin: "NoNetRegistrationForwardingWitness")
    witness = registrar
    return registrar
  }
  func valuePublished(byPlugin key: String) -> NSObject? { original.valuePublished(byPlugin: key) }
}

@MainActor private final class RegistrarProbe: NSObject, @preconcurrency FlutterPluginRegistrar {
  let base: FlutterPluginRegistrar
  weak var delegate: FlutterPlugin?
  var delegateCalls = 0, factoryCalls = 0
  var lastChannel: FlutterMethodChannel?
  weak var applicationDelegate: FlutterAppLifecycleDelegate?
  init(base: FlutterPluginRegistrar) { self.base = base }
  var messenger: FlutterBinaryMessenger { base.messenger }
  var textures: FlutterTextureRegistry { base.textures }
  var view: NSView? { base.view }
  var viewController: NSViewController? { base.viewController }
  func addMethodCallDelegate(_ delegate: FlutterPlugin, channel: FlutterMethodChannel) {
    self.delegate = delegate; lastChannel = channel; delegateCalls += 1
    base.addMethodCallDelegate(delegate, channel: channel)
  }
  func addApplicationDelegate(_ delegate: FlutterAppLifecycleDelegate) {
    applicationDelegate = delegate
    base.addApplicationDelegate(delegate)
  }
  func register(_ factory: FlutterPlatformViewFactory, withId id: String) {
    factoryCalls += 1; base.register(factory, withId: id)
  }
  func publish(_ value: NSObject) { base.publish(value) }
  func lookupKey(forAsset asset: String) -> String { base.lookupKey(forAsset: asset) }
  func lookupKey(forAsset asset: String, fromPackage package: String) -> String {
    base.lookupKey(forAsset: asset, fromPackage: package)
  }
}

@MainActor private final class ForeignPlugin: NSObject, @preconcurrency FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {}
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) { result(FlutterMethodNotImplemented) }
}
private final class LifecycleProbe: NSObject, FlutterAppLifecycleDelegate {}
#endif

#if os(macOS)
import AVFoundation
import AudioToolbox
import CoreMedia
import UniformTypeIdentifiers
import CryptoKit

private enum SegmentProbeError: Error { case rejected(String) }

private final class ProbeSegments: NSObject, AVAssetWriterDelegate {
  private let lock = NSLock()
  private var chunks: [Data] = []
  private var kinds: [AVAssetSegmentType] = []
  private var count = 0
  private var refused = false
  func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData data: Data,
                   segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
    lock.lock(); defer { lock.unlock() }
    // Existing GStreamer/Windows byte bound, not a new product quota.
    guard count <= 10 * 1024 * 1024 - data.count else { refused = true; return }
    chunks.append(data.withUnsafeBytes { Data($0) })
    count += data.count; kinds.append(segmentType)
  }
  func snapshot() throws -> Data {
    lock.lock(); defer { lock.unlock() }
    guard !refused, kinds.first == .initialization, kinds.contains(.separable), count > 0 else {
      throw SegmentProbeError.rejected("No complete initialization/media sequence")
    }
    return chunks.reduce(into: Data(), { $0.append($1) })
  }
}

enum SegmentedWriterProbe {
  static func stage(_ value: String) { print("AAC_STAGE:\(value)"); fflush(stdout) }
  static func require(_ value: Bool, _ context: String) throws {
    if !value { throw SegmentProbeError.rejected(context) }
  }

  static func run() async throws {
    try require(!Thread.isMainThread, "Codec must run off the UI thread")
    stage("begin")
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 20_000]
    let segments = ProbeSegments()
    let writer = AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue)!)
    writer.outputFileTypeProfile = .mpeg4AppleHLS
    writer.initialSegmentStartTime = .zero
    // Apple WWDC20 session10011, Configure AVAssetWriter at 6:28.
    // Manual/indefinite mode at 13:45 only permits already encoded passthrough.
    writer.preferredOutputSegmentInterval = CMTime(seconds: 6.0, preferredTimescale: 1)
    writer.delegate = segments
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
    try require(writer.canApply(outputSettings: settings, forMediaType: .audio), "AAC settings refused")
    try require(writer.canAdd(input), "Audio input refused")
    writer.add(input)

    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                               channels: 1, interleaved: true)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
    pcm.frameLength = 16_000
    let audio = pcm.mutableAudioBufferList.pointee.mBuffers
    guard let bytes = audio.mData else { throw SegmentProbeError.rejected("No PCM bytes") }
    memset(bytes, 0, Int(audio.mDataByteSize)) // Synthetic silence only.
    var description: CMAudioFormatDescription?
    try require(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
      asbd: format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0,
      magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr, "PCM description")
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 16_000),
      presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    try require(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil,
      dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
      sampleCount: 16_000, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
      sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, "PCM sample")
    guard let sample else { throw SegmentProbeError.rejected("Missing sample") }
    try require(CMSampleBufferSetDataBufferFromAudioBufferList(sample,
      blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
      bufferList: pcm.audioBufferList) == noErr, "Owned PCM copy")
    try require(CMSampleBufferSetDataReady(sample) == noErr, "PCM readiness")
    stage("start-writing")
    try require(writer.startWriting(), "Writer start: \(String(describing: writer.error))")
    writer.startSession(atSourceTime: .zero)
    stage("session-started")
    try require(input.isReadyForMoreMediaData, "Initial backpressure; no polling assumed")
    try require(input.append(sample), "PCM append: \(String(describing: writer.error))")
    stage("appended")
    input.markAsFinished()
    stage("finish-writing")
    await writer.finishWriting()
    stage("writer-finished")
    try require(writer.status == .completed, "Writer finish: \(String(describing: writer.error))")
    let data = try segments.snapshot()
    stage("segments-joined:\(data.count)")
    try require(!Thread.isMainThread, "Codec finalization must stay off the UI thread")
    stage("detach-delegate")
    writer.delegate = nil
    stage("delegate-detached")

    stage("temporary-directory")
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    stage("create-directory")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
    stage("directory-created")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let url = temporary.appendingPathComponent("synthetic.m4a")
    stage("write-file")
    try data.write(to: url, options: .withoutOverwriting)
    stage("file-written")
    stage("open-asset")
    let asset = AVURLAsset(url: url)
    stage("asset-opened")
    stage("load-duration")
    let duration = try await asset.load(.duration)
    stage("duration-loaded:\(duration.seconds)")
    stage("load-tracks")
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    stage("tracks-loaded")
    try require(tracks.count == 1 && duration.seconds.isFinite && duration.seconds > 0, "Audio metadata")
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
    try require(reader.canAdd(output), "Audio decode output")
    reader.add(output)
    try require(reader.startReading(), "Audio decode start")
    stage("decode")
    var frames = 0
    while let decoded = output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(decoded) }
    stage("decoded:\(frames)")
    try require(reader.status == .completed && frames >= 16_000, "Audio decode complete")
    let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    print("AAC_SEGMENT_PROBE_OK:bytes=\(data.count),duration=\(duration.seconds),frames=\(frames),sha256=\(sha)")
    fflush(stdout)
  }
}
#endif
