import Cocoa
import FlutterMacOS
import Security

class MainFlutterWindow: NSWindow {
  private var notificationActions: NotificationActions?
  private var localMedia: AppleLocalMediaPlugin?
  private var storageChannel: FlutterMethodChannel?
  private var closingWindow = false
  private var pendingQuit: (() -> Void)?
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
      guard call.method == "privateTemporaryDirectory" else {
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
        result(nil)
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
    NotificationCenter.default.addObserver(self, selector: #selector(willTerminate(_:)),
      name: NSApplication.willTerminateNotification, object: nil)

    super.awakeFromNib()
  }

  override func close() {
    closingWindow = true
    guard localMedia?.requestClose() != false else { return }
    guard localMedia?.detach() != false else { return }
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
