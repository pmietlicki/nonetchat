import Cocoa
import FlutterMacOS
import Security

class MainFlutterWindow: NSWindow {
  private var notificationActions: NotificationActions?
  private var localMedia: AppleLocalMediaPlugin?
  private var storageChannel: FlutterMethodChannel?
  private var closingWindow = false
  private var pendingQuit: (() -> Void)?
  private var lockWindowChannel: FlutterMethodChannel?
  private var protectLockWindow = UserDefaults.standard.bool(forKey: "flutter.application_lock_enabled")
  private var lockWindowCover: NSView?
  private var lockWindowTicket: String?
  private let lockWindowIdentity = UUID().uuidString

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    let receivedAudio = AppleWebRTCRegistration.register(in: flutterViewController) {
      RegisterGeneratedPlugins(registry: $0)
    }
    notificationActions = NotificationActions(messenger: flutterViewController.engine.binaryMessenger)
    let media = AppleLocalMediaPlugin(messenger: flutterViewController.engine.binaryMessenger,
      receivedAudio: receivedAudio)
    localMedia = media
    media.onDrained = { [weak self] in
      guard let self else { return }
      if let quit = self.pendingQuit {
        self.pendingQuit = nil
        quit()
      } else if self.closingWindow { self.close() }
    }
    AppleFastLanePlugin.register(with: flutterViewController.registrar(forPlugin: "NoNetChatAppleFastLane"))
    let storage = FlutterMethodChannel(name: "com.nonetchat/native_utils",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    storage.setMethodCallHandler { call, result in
      let deferred = DeferredPrekeyFiles.handles(call.method)
      guard call.method == "privateTemporaryDirectory" || deferred else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let task = SecTaskCreateFromSelf(nil) else {
        result(FlutterError(code: "IO_ERROR", message: "Temporary storage unavailable", details: nil))
        return
      }
      var error: Unmanaged<CFError>?
      let entitlement = SecTaskCopyValueForEntitlement(task,
        "com.apple.security.app-sandbox" as CFString, &error)
      if let error {
        _ = error.takeRetainedValue()
        result(FlutterError(code: "IO_ERROR", message: "Temporary storage unavailable", details: nil))
        return
      }
      guard entitlement as? Bool == true else {
        result(deferred && call.method != "eraseDeferredPrekeyFiles"
          ? FlutterError(code: "IO_ERROR", message: "Secure storage unavailable", details: nil)
          : nil)
        return
      }
      if deferred {
        DeferredPrekeyFiles.handle(call, result)
        return
      }
      let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
      let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      guard temporary.path.hasPrefix(home.path + "/") else {
        result(FlutterError(code: "IO_ERROR", message: "Temporary storage unavailable", details: nil))
        return
      }
      result(temporary.path)
    }
    storageChannel = storage
    registerLockWindow(flutterViewController.engine.binaryMessenger)
    NotificationCenter.default.addObserver(self, selector: #selector(coverLockWindow(_:)),
      name: NSApplication.willResignActiveNotification, object: nil)

    NotificationCenter.default.addObserver(self, selector: #selector(willTerminate(_:)),
      name: NSApplication.willTerminateNotification, object: nil)

    super.awakeFromNib()
  }

  @objc private func coverLockWindow(_ notification: Notification? = nil) {
    guard protectLockWindow, let original = contentView else { return }
    lockWindowCover?.removeFromSuperview()
    let cover = NSView(frame: original.bounds)
    cover.autoresizingMask = [.width, .height]
    cover.wantsLayer = true
    cover.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    original.addSubview(cover, positioned: .above, relativeTo: nil)
    lockWindowCover = cover
    lockWindowTicket = UUID().uuidString
  }

  private func removeLockWindowCover() {
    lockWindowCover?.removeFromSuperview()
    lockWindowCover = nil
    lockWindowTicket = nil
  }

  private func registerLockWindow(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "com.nonetchat/application_lock_window",
      binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(false); return }
      switch call.method {
      case "identity": result(self.lockWindowIdentity)
      case "setProtected":
        guard let args = call.arguments as? [String: Any],
              args["window"] as? String == self.lockWindowIdentity,
              let value = args["enabled"] as? Bool,
              self.contentView != nil else {
          result(false); return
        }
        self.protectLockWindow = value
        if !value { self.removeLockWindowCover() }
        else if !NSApp.isActive { self.coverLockWindow() }
        result(true)
      case "paintTicket":
        guard self.lockWindowCover?.window === self else { result(nil); return }
        result(self.lockWindowTicket)
      case "painted":
        guard NSApp.isActive, self.isVisible,
              let ticket = call.arguments as? String, ticket == self.lockWindowTicket,
              self.lockWindowCover?.window === self else { result(false); return }
        self.removeLockWindowCover()
        result(true)
      default: result(FlutterMethodNotImplemented)
      }
    }
    lockWindowChannel = channel
  }

  override func close() {
    closingWindow = true
    guard localMedia?.requestClose() != false else { return }
    guard localMedia?.detach() != false else { return }
    NotificationCenter.default.removeObserver(self,
      name: NSApplication.willResignActiveNotification, object: nil)
    lockWindowChannel?.setMethodCallHandler(nil)
    lockWindowChannel = nil
    removeLockWindowCover()
    NotificationCenter.default.removeObserver(self, name: NSApplication.willTerminateNotification, object: nil)
    super.close()
  }

  // AppKit's terminateLater keeps the engine until SDK/OUTPUT and the native
  // indication have drained. An unconfirmed release deliberately keeps it open.
  func prepareToTerminate(_ completion: @escaping () -> Void) -> Bool {
    pendingQuit = completion
    if localMedia?.requestClose() != false {
      pendingQuit = nil
      return true
    }
    return false
  }

  func cancelTermination() {
    pendingQuit = nil
    if closingWindow { close() }
    else { _ = localMedia?.cancelClose() }
  }

  @objc private func willTerminate(_ notification: Notification) {
    _ = localMedia?.detach()
    NotificationCenter.default.removeObserver(self, name: NSApplication.willTerminateNotification, object: nil)
  }
}
