import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let window = sender.windows.compactMap({ $0 as? MainFlutterWindow }).first else {
      return super.applicationShouldTerminate(sender)
    }
    if window.prepareToTerminate({ [weak self] in self?.replyAfterMediaDrained(sender) }) {
      return super.applicationShouldTerminate(sender)
    }
    return .terminateLater
  }

  private func replyAfterMediaDrained(_ sender: NSApplication) {
    // Preserve Flutter's existing cancelable Dart exit handshake. Its async
    // cancellation/retry is distinct from our native media drain.
    let reply = super.applicationShouldTerminate(sender)
    if reply != .terminateLater {
      sender.reply(toApplicationShouldTerminate: reply == .terminateNow)
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
