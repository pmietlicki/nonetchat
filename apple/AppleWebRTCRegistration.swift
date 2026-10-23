import Foundation
import WebRTC
#if os(iOS)
import Flutter
import UIKit
#elseif os(macOS)
import FlutterMacOS
import AppKit
#endif
#if canImport(flutter_webrtc)
import flutter_webrtc
#endif

/// The lifetime witness is published through a distinct, engine-owned registrar.
/// This object never owns the registry, witness, SDK instance or another engine.
@MainActor final class AppleRegisteredAudioSource {
  private let plugin: RegisteredPluginSource<FlutterWebRTCPlugin>

  fileprivate init(scope: AnyObject, lifetime: AnyObject) {
    plugin = RegisteredPluginSource(scope: scope, lifetime: lifetime)
  }

  fileprivate func observe(_ value: FlutterWebRTCPlugin) { plugin.observe(value) }
  var isRegistered: Bool { plugin.current != nil }
  func retire() { plugin.retire() }

  func directory(current: @escaping () -> Bool) -> ReceivedAudioSources {
    AppleReceivedAudioSources.directory(current: { [weak self] in
      guard let self, self.plugin.current != nil else { return false }
      let allowed = current()
      return allowed && self.plugin.current != nil
    }, peer: { [weak self] id in
      self?.plugin.current?.peerConnections?[id] as? RTCPeerConnection
    })
  }
}

@MainActor enum AppleWebRTCRegistration {
  static func register(in registry: NSObject & FlutterPluginRegistry,
                       generated: (NSObject & FlutterPluginRegistry) -> Void) -> AppleRegisteredAudioSource? {
    // Hold only during registration. Flutter owns the publication afterwards.
    let lifetime = NSObject()
    #if os(iOS)
    guard let registrar = registry.registrar(forPlugin: "NoNetChatReceivedAudioScope") else {
      generated(registry) // Ordinary SDK registration is never made conditional.
      return nil
    }
    #else
    let registrar = registry.registrar(forPlugin: "NoNetChatReceivedAudioScope")
    #endif
    registrar.publish(lifetime)
    let source = AppleRegisteredAudioSource(scope: registry, lifetime: lifetime)
    generated(ObservedPluginRegistry(base: registry, source: source))
    return source
  }
}

/// This short-lived object is used only while the generated registrant runs.
/// Other plugins receive their exact original registrar. No generated file or
/// SDK method/event channel is replaced, decorated or unpublished.
@MainActor private final class ObservedPluginRegistry: NSObject, @preconcurrency FlutterPluginRegistry {
  let base: NSObject & FlutterPluginRegistry
  let source: AppleRegisteredAudioSource
  init(base: NSObject & FlutterPluginRegistry, source: AppleRegisteredAudioSource) {
    self.base = base; self.source = source
  }

  #if os(iOS)
  func registrar(forPlugin key: String) -> FlutterPluginRegistrar? {
    guard let registrar = base.registrar(forPlugin: key) else { return nil }
    return key == "FlutterWebRTCPlugin" ? ObservedPluginRegistrar(base: registrar, source: source) : registrar
  }
  func hasPlugin(_ key: String) -> Bool { base.hasPlugin(key) }
  #else
  func registrar(forPlugin key: String) -> FlutterPluginRegistrar {
    let registrar = base.registrar(forPlugin: key)
    return key == "FlutterWebRTCPlugin" ? ObservedPluginRegistrar(base: registrar, source: source) : registrar
  }
  #endif
  func valuePublished(byPlugin key: String) -> NSObject? { base.valuePublished(byPlugin: key) }
}

/// The SDK retains this registrar. It owns only Flutter's original registrar
/// and holds our source weakly, so it cannot retain the app/window/registry.
private final class ObservedPluginRegistrar: NSObject, FlutterPluginRegistrar {
  let base: FlutterPluginRegistrar
  weak var source: AppleRegisteredAudioSource?
  init(base: FlutterPluginRegistrar, source: AppleRegisteredAudioSource) {
    self.base = base; self.source = source
  }

  private func observe(_ delegate: FlutterPlugin) {
    guard let sdk = delegate as? FlutterWebRTCPlugin else { return }
    // Only the generated registration is an admission path. Forward ordinary
    // registrar methods on their caller's thread, just as Flutter does; never
    // make an asset/texture lookup acquire a new main-actor precondition.
    if Thread.isMainThread {
      MainActor.assumeIsolated { source?.observe(sdk) }
    } else {
      Task { @MainActor [weak source] in source?.retire() }
    }
  }

  #if os(iOS)
  func messenger() -> FlutterBinaryMessenger { base.messenger() }
  func textures() -> FlutterTextureRegistry { base.textures() }
  var viewController: UIViewController? { base.viewController }
  func addMethodCallDelegate(_ delegate: FlutterPlugin, channel: FlutterMethodChannel) {
    observe(delegate)
    base.addMethodCallDelegate(delegate, channel: channel)
  }
  func addApplicationDelegate(_ delegate: FlutterPlugin) { base.addApplicationDelegate(delegate) }
  @available(iOS 13.0, *)
  func addSceneDelegate(_ delegate: FlutterSceneLifeCycleDelegate) { base.addSceneDelegate(delegate) }
  func register(_ factory: FlutterPlatformViewFactory, withId id: String) { base.register(factory, withId: id) }
  func register(_ factory: FlutterPlatformViewFactory, withId id: String,
                gestureRecognizersBlockingPolicy policy: FlutterPlatformViewGestureRecognizersBlockingPolicy) {
    base.register(factory, withId: id, gestureRecognizersBlockingPolicy: policy)
  }
  func valuePublished(byPlugin key: String) -> NSObject? { base.valuePublished(byPlugin: key) }
  #else
  var messenger: FlutterBinaryMessenger { base.messenger }
  var textures: FlutterTextureRegistry { base.textures }
  var view: NSView? { base.view }
  var viewController: NSViewController? { base.viewController }
  func addMethodCallDelegate(_ delegate: FlutterPlugin, channel: FlutterMethodChannel) {
    observe(delegate)
    base.addMethodCallDelegate(delegate, channel: channel)
  }
  func addApplicationDelegate(_ delegate: FlutterAppLifecycleDelegate) { base.addApplicationDelegate(delegate) }
  func register(_ factory: FlutterPlatformViewFactory, withId id: String) { base.register(factory, withId: id) }
  #endif

  func publish(_ value: NSObject) { base.publish(value) }
  func lookupKey(forAsset asset: String) -> String { base.lookupKey(forAsset: asset) }
  func lookupKey(forAsset asset: String, fromPackage package: String) -> String {
    base.lookupKey(forAsset: asset, fromPackage: package)
  }
}
