// Network.framework counterpart of google/nearby's GNCNWFramework and
// GNCNWParameters (1c1bcbe). See docs/fast-lane-apple.md for the security model.
// All ownership and callbacks stay on the main queue; networking is asynchronous.
import Foundation
import Network
import Security
#if os(iOS)
import Flutter
import UIKit
#else
import FlutterMacOS
import AppKit
#endif
#if os(iOS) && canImport(WiFiAware)
import WiFiAware
#endif

final class AppleFastLanePlugin: NSObject, FlutterPlugin {
  @MainActor private var owner: AppleTransferPipe?
  // One current radio route hint, RAM only. This never creates app trust.
  @MainActor private var awareRoute: (pin: String, device: UInt64)?
  static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(name: "fr.pmietlicki.nonetchat/apple_fast_lane", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(AppleFastLanePlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    DispatchQueue.main.async { self.handleOnMain(call, result: result) }
  }

  @MainActor private func handleOnMain(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "dispose" {
      // Backend close first drains its token; never discard another owner.
      guard owner == nil else { result(Self.error("BUSY")); return }
      awareRoute = nil
      result(nil); return
    }
    if call.method == "state" {
      #if targetEnvironment(simulator)
      result(["peerToPeer": false, "pairedAware": false])
      #else
      pairedAwareAvailable { available in
        result(["peerToPeer": true, "pairedAware": available])
      }
      #endif
      return
    }
    guard let args = call.arguments as? [String: Any],
          let token = args["token"] as? String,
          token.range(of: "^[A-Za-z0-9_-]{24}$", options: .regularExpression) != nil else {
      result(Self.error("INVALID")); return
    }
    if call.method == "stop" {
      if owner?.token == token { owner?.close(); owner = nil }
      result(nil); return
    }
    if call.method == "connect" {
      guard owner == nil, Self.isForeground,
            let secret = args["secret"] as? FlutterStandardTypedData, secret.data.count == 32,
            let role = args["role"] as? String, ["listener", "connector"].contains(role),
            let medium = args["medium"] as? String, ["applePeerToPeer", "wifiAware"].contains(medium) else {
        result(Self.error("UNAVAILABLE")); return
      }
      let pin = args["peerPin"] as? String
      let hint = pin == awareRoute?.pin ? awareRoute?.device : nil
      let pipe = AppleTransferPipe(token: token, listener: role == "listener", secret: secret.data,
          awareDevice: hint, onAwareConnected: { [weak self] device in
            if let device = device, let pin = pin, pin.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil {
              self?.awareRoute = (pin, device)
            } else if self?.awareRoute?.pin == pin {
              self?.awareRoute = nil
            }
          })
      owner = pipe
      do { try pipe.open(aware: medium == "wifiAware", mayPrompt: args["mayPrompt"] as? Bool == true,
                         pairLabel: args["pairLabel"] as? String ?? "",
                         cancelLabel: args["cancelLabel"] as? String ?? "",
                         rtl: args["rtl"] as? Bool == true, result: result) }
      catch { pipe.close(); owner = nil }
      return
    }
    guard let pipe = owner, pipe.token == token else { result(Self.error("CLOSED")); return }
    switch call.method {
    case "read": pipe.read(result)
    case "write":
      guard let bytes = args["bytes"] as? FlutterStandardTypedData else { result(Self.error("INVALID")); return }
      pipe.write(bytes.data, result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  @MainActor static var isForeground: Bool {
    #if os(iOS)
    return UIApplication.shared.applicationState == .active
    #else
    return NSApp.isActive
    #endif
  }
  static func error(_ code: String) -> FlutterError {
    FlutterError(code: code, message: "Temporary Apple link unavailable", details: nil)
  }

  /// Wi-Fi Aware's system pairing is independent of NoNetChat verification.
  /// Never advertise Android NAN compatibility or invent a paired device.
  @MainActor private func pairedAwareAvailable(_ reply: @escaping (Bool) -> Void) {
    #if os(iOS) && canImport(WiFiAware) && canImport(DeviceDiscoveryUI)
    if #available(iOS 26.0, *),
       Bundle.main.object(forInfoDictionaryKey: "NoNetPairedAwareEnabled") as? Bool == true,
       WACapabilities.supportedFeatures.contains(.wifiAware) {
      reply(true)
      return
    }
    #endif
    reply(false)
  }
}

@MainActor
private final class AppleTransferPipe {
  static let service = "_nonet-fast._tcp"
  static let maxFrame = 65536 // SecureSession.maxPacketBytes
  let token: String
  private let listening: Bool
  private var secret: Data
  private var listener: NWListener?
  private var browser: NWBrowser?
  private var candidates: [ObjectIdentifier: NWConnection] = [:]
  private var connection: NWConnection?
  private var opening: FlutterResult?
  private var reading: FlutterResult?
  private var writing: FlutterResult?
  private var closed = false
  private var pairing: ApplePairingLease?
  private var selecting: Task<Void, Never>?
  private var awareDevice: UInt64?
  private let onAwareConnected: @MainActor (UInt64?) -> Void

  init(token: String, listener: Bool, secret: Data, awareDevice: UInt64?, onAwareConnected: @escaping @MainActor (UInt64?) -> Void) {
    self.token = token; listening = listener; self.secret = secret
    self.awareDevice = awareDevice; self.onAwareConnected = onAwareConnected
  }

  private func parameters() -> NWParameters {
    // Same TLS-PSK suite/version as Nearby GNCConfigureTLSOptions. The key is
    // random per transfer, carried only by the existing private control path.
    let tls = NWProtocolTLS.Options()
    let options = tls.securityProtocolOptions
    sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
    sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: TLS_PSK_WITH_AES_128_GCM_SHA256)!)
    let key = secret.withUnsafeBytes { DispatchData(bytes: $0) }
    let identity = Data(token.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
    sec_protocol_options_add_pre_shared_key(options, key as dispatch_data_t, identity as dispatch_data_t)
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let parameters = NWParameters(tls: tls, tcp: tcp)
    parameters.includePeerToPeer = true
    parameters.prohibitedInterfaceTypes = [.cellular, .loopback]
    return parameters
  }

  func open(aware: Bool, mayPrompt: Bool, pairLabel: String, cancelLabel: String, rtl: Bool, result: @escaping FlutterResult) throws {
    opening = result
    if aware {
      #if os(iOS) && canImport(WiFiAware) && canImport(DeviceDiscoveryUI)
      if #available(iOS 26.0, *),
         Bundle.main.object(forInfoDictionaryKey: "NoNetPairedAwareEnabled") as? Bool == true,
         WACapabilities.supportedFeatures.contains(.wifiAware) {
        if let device = awareDevice {
          selectAwareDevice(device)
        } else {
          guard mayPrompt, !pairLabel.isEmpty, !cancelLabel.isEmpty else { throw PipeFailure.unavailable }
          pairing = AppleAwarePairing.present(listening: listening, label: pairLabel, cancelLabel: cancelLabel, rtl: rtl,
              onSelect: { [weak self] device in self?.selectAwareDevice(device) },
              onCancel: { [weak self] in self?.close() })
          guard pairing != nil else { throw PipeFailure.unavailable }
        }
        return
      } else { throw PipeFailure.unavailable }
      #else
      throw PipeFailure.unavailable
      #endif
    }
    try openNetwork(parameters(), service: NWListener.Service(name: token, type: Self.service),
                    descriptor: .bonjour(type: Self.service, domain: "local."), aware: false)
  }

  #if os(iOS) && canImport(WiFiAware)
  @available(iOS 26.0, *)
  private func selectAwareDevice(_ id: UInt64) {
    guard !closed, selecting == nil else { return }
    pairing?.close(); pairing = nil
    let cached = awareDevice == id
    selecting = Task { @MainActor [weak self] in
      guard let self = self else { return }
      do {
        for try await devices in WAPairedDevice.allDevices {
          guard !self.closed, !Task.isCancelled else { return }
          guard let device = devices[id] else {
            if cached { self.onAwareConnected(nil); self.close(); return }
            continue
          }
          self.awareDevice = id
          var parameters = self.parameters()
          if self.listening {
            guard let service = WAPublishableService.allServices[Self.service] else { throw PipeFailure.unavailable }
            let provider: WAPublisherListener = .wifiAware(.connecting(to: service, from: .selected([device])))
            provider.configureParameters(parameters)
            try self.openNetwork(parameters, service: provider.service, descriptor: .bonjour(type: Self.service, domain: "local."), aware: true)
          } else {
            guard let service = WASubscribableService.allServices[Self.service] else { throw PipeFailure.unavailable }
            let provider: WASubscriberBrowser = .wifiAware(.connecting(to: .selected([device]), from: service))
            parameters = provider.configureParameters(parameters)
            try self.openNetwork(parameters, service: NWListener.Service(name: self.token, type: Self.service), descriptor: provider.makeDescriptor(), aware: true)
          }
          return
        }
      } catch { self.close() }
    }
  }
  #endif

  private func openNetwork(_ parameters: NWParameters, service: NWListener.Service, descriptor: NWBrowser.Descriptor, aware: Bool) throws {
    if listening {
      let listener = try NWListener(using: parameters)
      self.listener = listener
      listener.service = service
      listener.newConnectionHandler = { [weak self] candidate in
        DispatchQueue.main.async { self?.consider(candidate) }
      }
      listener.stateUpdateHandler = { [weak self] state in
        DispatchQueue.main.async {
          if case .failed = state { self?.close() }
        }
      }
      listener.start(queue: .main)
    } else {
      openBrowser(descriptor, parameters, aware: aware)
    }
  }

  private func openBrowser(_ descriptor: NWBrowser.Descriptor, _ parameters: NWParameters, aware: Bool) {
    let browser = NWBrowser(for: descriptor, using: parameters)
    self.browser = browser
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      DispatchQueue.main.async {
        guard let self = self, !self.closed, self.connection == nil else { return }
        for found in results {
          if !aware {
            // The browser already selects the service type. Bonjour names are
            // DNS case-insensitive; authentication still requires the full PSK.
            guard case .service(let name, _, _, _) = found.endpoint,
                  name.caseInsensitiveCompare(self.token) == .orderedSame else { continue }
          }
          // The TLS PSK selects this transfer even amongst OS-paired endpoints.
          if self.candidates.values.contains(where: { $0.endpoint == found.endpoint }) { continue }
          self.consider(NWConnection(to: found.endpoint, using: parameters))
        }
      }
    }
    browser.stateUpdateHandler = { [weak self] state in
      DispatchQueue.main.async {
        if case .failed = state { self?.close() }
      }
    }
    browser.start(queue: .main)
  }

  private func consider(_ candidate: NWConnection) {
    // Existing six-handshake admission bound. Failed TLS candidates never own
    // the transfer; a stranger cannot win merely by connecting first.
    guard !closed, connection == nil, candidates.count < 6 else { candidate.cancel(); return }
    let id = ObjectIdentifier(candidate)
    candidates[id] = candidate
    candidate.stateUpdateHandler = { [weak self, weak candidate] state in
      DispatchQueue.main.async {
        guard let self = self, let candidate = candidate, !self.closed else { return }
        switch state {
        case .ready:
          if self.connection === candidate { return }
          guard self.connection == nil else { candidate.cancel(); return }
          self.connection = candidate
          for (key, other) in self.candidates where key != id { other.cancel() }
          self.candidates.removeAll(); self.browser?.cancel(); self.browser = nil
          self.listener?.cancel(); self.listener = nil
          self.pairing?.close(); self.pairing = nil
          if let device = self.awareDevice { self.onAwareConnected(device) }
          self.secret.resetBytes(in: 0..<self.secret.count)
          let reply = self.opening; self.opening = nil; reply?(nil)
        case .failed, .cancelled:
          self.candidates.removeValue(forKey: id)
          if self.connection === candidate { self.close() }
        default: break
        }
      }
    }
    candidate.start(queue: .main)
    // Nearby's native Apple TCP/TLS connect budget is four seconds.
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak candidate] in
      guard let self = self, let candidate = candidate, self.candidates[id] != nil else { return }
      self.candidates.removeValue(forKey: id); candidate.cancel()
    }
  }

  func read(_ result: @escaping FlutterResult) {
    guard !closed, reading == nil, let connection = connection else { result(AppleFastLanePlugin.error("CLOSED")); return }
    reading = result
    receive(connection, count: 4, accumulated: Data()) { [weak self] header in
      guard let self = self, !self.closed else { return }
      guard let header = header else { self.close(); return }
      let length = header.reduce(0) { ($0 << 8) | Int($1) }
      guard (1...Self.maxFrame).contains(length) else { self.close(); return }
      self.receive(connection, count: length, accumulated: Data()) { [weak self] payload in
        guard let self = self, !self.closed else { return }
        guard let payload = payload else { self.close(); return }
        let reply = self.reading; self.reading = nil
        reply?(FlutterStandardTypedData(bytes: payload))
      }
    }
  }

  private func receive(_ connection: NWConnection, count: Int, accumulated: Data, completion: @escaping (Data?) -> Void) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: count - accumulated.count) { [weak self] bytes, _, complete, error in
      DispatchQueue.main.async {
        guard let self = self, !self.closed else { return }
        var data = accumulated
        if let bytes = bytes { data.append(bytes) }
        if data.count == count { completion(data) }
        else if error != nil || complete || bytes?.isEmpty != false { completion(nil) }
        else { self.receive(connection, count: count, accumulated: data, completion: completion) }
      }
    }
  }

  func write(_ bytes: Data, _ result: @escaping FlutterResult) {
    guard !closed, writing == nil, let connection = connection,
          (1...Self.maxFrame).contains(bytes.count) else { result(AppleFastLanePlugin.error("CLOSED")); return }
    writing = result
    let length = UInt32(bytes.count)
    var frame = Data([UInt8(length >> 24), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
    frame.append(bytes)
    connection.send(content: frame, completion: .contentProcessed { [weak self] error in
      DispatchQueue.main.async {
        guard let self = self, !self.closed else { return }
        let reply = self.writing; self.writing = nil
        reply?(error == nil ? nil : AppleFastLanePlugin.error("CONNECTION"))
        if error != nil { self.close() }
      }
    })
  }

  func close() {
    guard !closed else { return }; closed = true
    browser?.cancel(); listener?.cancel(); connection?.cancel()
    pairing?.close(); pairing = nil
    selecting?.cancel(); selecting = nil
    for candidate in candidates.values { candidate.cancel() }
    candidates.removeAll(); secret.resetBytes(in: 0..<secret.count)
    let replies = [opening, reading, writing]; opening = nil; reading = nil; writing = nil
    for reply in replies { reply?(AppleFastLanePlugin.error("CLOSED")) }
  }
  private enum PipeFailure: Error { case unavailable }
}

@MainActor protocol ApplePairingLease: AnyObject { func close() }
