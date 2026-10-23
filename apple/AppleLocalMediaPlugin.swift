import Foundation
import CoreFoundation
import Darwin
#if os(iOS)
import Flutter
import UIKit
#else
import FlutterMacOS
import AppKit
#endif

/// Retained by the owning engine/window, never by a process-global registry.
@MainActor final class AppleLocalMediaPlugin {
  private let channel: FlutterMethodChannel
  private let host: LocalMediaHost
  private var calls = 0
  private var detached = false
  var onDrained: (@MainActor () -> Void)?

  #if os(iOS)
  let presentation: IOSLocalMediaPresentation
  init(messenger: FlutterBinaryMessenger, actions: NotificationActions) {
    presentation = IOSLocalMediaPresentation(actions: actions)
    host = LocalMediaHost(platform: presentation, clock: Self.continuousMs)
    channel = FlutterMethodChannel(name: "fr.pmietlicki.nonetchat/local_media", binaryMessenger: messenger)
    connect()
  }
  #else
  init(messenger: FlutterBinaryMessenger) {
    host = LocalMediaHost(platform: MacLocalMediaPresentation(), clock: Self.continuousMs)
    channel = FlutterMethodChannel(name: "fr.pmietlicki.nonetchat/local_media", binaryMessenger: messenger)
    connect()
  }
  #endif

  static func continuousMs() -> Double {
    // Same suspend-inclusive source as NotificationActions.continuousMs.
    var info = mach_timebase_info_data_t()
    guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else { return .nan }
    return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000
  }

  private func connect() {
    host.onStop = { [weak self] key in
      guard let self, !self.detached else { return }
      let channel = self.channel // Retain across a synchronous/reentrant SDK send.
      channel.invokeMethod("stop", arguments: ["token": key.token, "account": key.account])
    }
    host.onDrained = { [weak self] in self?.drained() }
    channel.setMethodCallHandler { [weak self] call, result in
      Task { @MainActor in
        guard let self, !self.detached else { return }
        self.calls += 1
        defer { self.calls -= 1; self.drained() }
        let value = await self.handle(call)
        if !self.detached { result(value) }
      }
    }
  }

  private static func flag(_ args: [String: Any], _ key: String, optional: Bool = false) -> Bool? {
    guard let value = args[key] else { return optional ? false : nil }
    guard let number = value as? NSNumber,
          CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
  }

  private func handle(_ call: FlutterMethodCall) async -> Any? {
    guard ["present", "capture", "active", "state", "recording", "release"].contains(call.method) else {
      return FlutterMethodNotImplemented
    }
    guard let args = call.arguments as? [String: Any],
          let token = args["token"] as? String,
          let account = args["account"] as? String else { return Self.failure() }
    if call.method == "present" {
      guard let role = args["role"] as? String, ["monitor", "listener"].contains(role),
            let normal = Self.flag(args, "normalMode"), let rtl = Self.flag(args, "rtl", optional: true),
            let title = args["title"] as? String, let body = args["body"] as? String,
            let stop = args["stop"] as? String, let stopping = args["stopping"] as? String else {
        return Self.failure()
      }
      return await host.present(token: token, account: account,
        role: role == "monitor" ? .monitor : .listener, normalMode: normal,
        title: title, body: body, stop: stop, stopping: stopping, rightToLeft: rtl)
    }
    // present may fail before reserving anything (foreground/permission/copy).
    // Dart still owns a possibly partial native publication and must reconcile.
    if call.method == "release", !host.hasOwner { return nil }
    guard let key = host.binding(token: token, account: account) else { return Self.failure() }
    switch call.method {
    case "capture": return await host.capture(key)
    case "active": return await host.active(key)
    case "state": return await host.state(key)
    case "recording":
      guard let nonce = args["recordingToken"] as? String, let on = Self.flag(args, "on") else {
        return Self.failure()
      }
      if on {
        guard let body = args["body"] as? String else { return Self.failure() }
        return await host.showRecording(key, nonce: nonce, body: body)
      }
      return await host.hideRecording(key, nonce: nonce)
    case "release": return await host.release(key) ? nil : Self.failure()
    default: return FlutterMethodNotImplemented
    }
  }

  private static func failure() -> FlutterError {
    FlutterError(code: "UNAVAILABLE", message: "Local media indication unavailable", details: nil)
  }

  private func drained() {
    guard !detached, calls == 0, host.isDrained else { return }
    onDrained?()
  }

  func requestClose() -> Bool { host.requestClose() && calls == 0 }
  func cancelClose() -> Bool { !detached && calls == 0 && host.cancelClose() }

  @discardableResult func detach() -> Bool {
    guard calls == 0, host.detach() else { return false }
    detached = true
    channel.setMethodCallHandler(nil)
    onDrained = nil
    return true
  }
}
