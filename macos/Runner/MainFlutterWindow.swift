import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var notificationActions: NotificationActions?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    notificationActions = NotificationActions(messenger: flutterViewController.engine.binaryMessenger)
    AppleFastLanePlugin.register(with: flutterViewController.registrar(forPlugin: "NoNetChatAppleFastLane"))

    super.awakeFromNib()
  }
}
