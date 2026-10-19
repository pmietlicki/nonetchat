import Flutter
import UIKit
import NetworkExtension
import Darwin

/// Like Nearby GNCHotspotMedium: an iPhone joins an Android-hosted network;
/// iOS does not expose local-only hotspot creation. Never request GPS/SSID scan.
final class AppleHotspotPlugin: NSObject, FlutterPlugin {
  @MainActor private var owner: AppleHotspotLease?
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "fr.pmietlicki.nonetchat/hotspot", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(AppleHotspotPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    DispatchQueue.main.async { self.handleOnMain(call, result: result) }
  }

  @MainActor private func handleOnMain(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "state" {
      #if targetEnvironment(simulator)
      result(["canHost": false, "canJoin": false])
      #else
      result(["canHost": false, "canJoin": true])
      #endif
      return
    }
    guard let args = call.arguments as? [String: Any], let token = args["token"] as? String,
          token.range(of: "^[A-Za-z0-9_-]{24}$", options: .regularExpression) != nil else {
      result(AppleFastLanePlugin.error("INVALID")); return
    }
    if call.method == "stop" {
      guard let lease = owner, lease.token == token else { result(nil); return }
      lease.stop { [weak self, weak lease] in
        if self?.owner === lease { self?.owner = nil }; result(nil)
      }
      return
    }
    guard call.method == "join" else { result(FlutterMethodNotImplemented); return }
    guard owner == nil, UIApplication.shared.applicationState == .active,
          let ssid = args["ssid"] as? String, (1...32).contains(ssid.utf8.count),
          !ssid.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
          let password = args["password"] as? String, (8...63).contains(password.utf8.count),
          password.utf8.allSatisfy({ (32...126).contains($0) }),
          let host = args["host"] as? String, AppleHotspotLease.privateIPv4(host) != nil else {
      result(AppleFastLanePlugin.error("INVALID")); return
    }
    let lease = AppleHotspotLease(token: token, ssid: ssid, host: host)
    owner = lease
    lease.join(password: password, reply: result)
  }
}

@MainActor
private final class AppleHotspotLease {
  let token: String
  private let ssid: String, host: String
  private var reply: FlutterResult?
  private var stopping: [() -> Void] = []
  private var closed = false, applying = false, ownsConfiguration = false
  private let manager = NEHotspotConfigurationManager.shared
  init(token: String, ssid: String, host: String) {
    self.token = token; self.ssid = ssid; self.host = host
  }

  func join(password: String, reply: @escaping FlutterResult) {
    self.reply = reply
    // Never replace or remove a configuration from an earlier app session.
    applying = true
    manager.getConfiguredSSIDs { [weak self] names in
      DispatchQueue.main.async {
        guard let self = self else { return }
        if self.closed { self.applying = false; self.finishStop(); return }
        guard !names.contains(self.ssid) else {
          self.applying = false; self.fail("UNAVAILABLE"); return
        }
        let configuration = NEHotspotConfiguration(ssid: self.ssid, passphrase: password, isWEP: false)
        configuration.joinOnce = true
        self.manager.apply(configuration) { [weak self] error in
          DispatchQueue.main.async {
            guard let self = self else { return }
            self.applying = false
            let code = (error as NSError?)?.code
            // A failed join may still have installed our new configuration.
            // We checked the app-owned list before applying it; user/other-app
            // configurations cannot be removed by this manager.
            self.ownsConfiguration = code != NEHotspotConfigurationError.alreadyAssociated.rawValue
            if self.closed { self.finishStop(); return }
            if let code = code, code != NEHotspotConfigurationError.alreadyAssociated.rawValue {
              self.fail(code == NEHotspotConfigurationError.userDenied.rawValue ? "PERMISSION" : "UNAVAILABLE")
              return
            }
            // apply success does not prove association. Check only this SSID
            // (never BSSID) and its private IPv4 before giving Dart a socket.
            self.awaitNetwork(attempts: 36)
          }
        }
      }
    }
  }

  private func awaitNetwork(attempts: Int) {
    guard !closed else { return }
    guard UIApplication.shared.applicationState == .active, attempts > 0 else { fail("UNAVAILABLE"); return }
    NEHotspotNetwork.fetchCurrent { [weak self] network in
      DispatchQueue.main.async {
        guard let self = self, !self.closed else { return }
        if network?.ssid == self.ssid, let address = self.localAddress() {
          let reply = self.reply; self.reply = nil
          reply?(["sourceAddress": address]); return
        }
        // Nearby GNCHotspotMedium's measured iOS join budget is 18 seconds;
        // use the existing 500ms passive address polling interval, no reapply.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
          self?.awaitNetwork(attempts: attempts - 1)
        }
      }
    }
  }

  private func localAddress() -> String? {
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0, let start = first else { return nil }
    defer { freeifaddrs(first) }
    var item: UnsafeMutablePointer<ifaddrs>? = start
    while let current = item {
      defer { item = current.pointee.ifa_next }
      guard String(cString: current.pointee.ifa_name) == "en0",
            let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
        let value = String(cString: buffer)
        if let mask = current.pointee.ifa_netmask,
           let local = Self.privateIPv4(value), let target = Self.privateIPv4(host) {
          var maskBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
          if getnameinfo(mask, socklen_t(mask.pointee.sa_len), &maskBuffer, socklen_t(maskBuffer.count), nil, 0, NI_NUMERICHOST) == 0 {
            let maskBytes = String(cString: maskBuffer).split(separator: ".").compactMap { Int($0) }
            if maskBytes.count == 4 && zip(local, target).enumerated().allSatisfy({
              ($0.element.0 & maskBytes[$0.offset]) == ($0.element.1 & maskBytes[$0.offset])
            }) { return value }
          }
        }
      }
    }
    return nil
  }
  static func privateIPv4(_ value: String) -> [Int]? {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    let bytes = parts.compactMap { Int($0) }
    guard bytes.count == 4, bytes.allSatisfy({ (0...255).contains($0) }),
          zip(parts, bytes).allSatisfy({ String($0.1) == $0.0 }) else { return nil }
    return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
      (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254) ? bytes : nil
  }
  private func fail(_ code: String) {
    let callback = reply; reply = nil
    callback?(AppleFastLanePlugin.error(code))
  }
  func stop(_ completion: @escaping () -> Void) {
    closed = true; stopping.append(completion)
    fail("CLOSED")
    if !applying { finishStop() }
  }
  private func finishStop() {
    if ownsConfiguration { manager.removeConfiguration(forSSID: ssid); ownsConfiguration = false }
    let callbacks = stopping; stopping.removeAll()
    for callback in callbacks { callback() }
  }
}
