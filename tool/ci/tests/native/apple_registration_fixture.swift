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
