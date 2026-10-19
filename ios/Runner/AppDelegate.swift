import Flutter
import UIKit
import UserNotifications
import MapKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var notificationActions: NotificationActions?
  private var mapsChannel: FlutterMethodChannel?
  private var storageChannel: FlutterMethodChannel?
  private var attachmentExport: AttachmentExport?
  override func userNotificationCenter(_ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    if NotificationActions.owns(response), let actions = notificationActions {
      actions.receive(response, completion: completionHandler)
    } else {
      super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
    }
  }
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = registrar(forPlugin: "NoNetChatNotificationActions") {
      UNUserNotificationCenter.current().delegate = self
      notificationActions = NotificationActions(messenger: registrar.messenger())
    }
    if let registrar = registrar(forPlugin: "NoNetChatStorage") {
      let channel = FlutterMethodChannel(name: "com.nonetchat/native_utils", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { [weak self] call, result in
        if call.method == "exportAttachment" {
          guard let self, self.attachmentExport == nil,
                UIApplication.shared.applicationState == .active,
                let args = call.arguments as? [String: Any],
                let path = args["path"] as? String,
                let name = args["name"] as? String,
                let root = self.window?.rootViewController else {
            result(FlutterError(code: "UNAVAILABLE", message: "Export unavailable", details: nil))
            return
          }
          do {
            let source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let folders: [(FileManager.SearchPathDirectory, String)] = [
              (.documentDirectory, "NoNetChatFiles"), (.cachesDirectory, "NoNetChatAudio")
            ]
            let allowed = try folders.map { entry in
              try FileManager.default.url(for: entry.0, in: .userDomainMask,
                  appropriateFor: nil, create: false)
                .appendingPathComponent(entry.1, isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL
            }
            let parent = source.deletingLastPathComponent().standardizedFileURL
            let values = try source.resourceValues(forKeys: [.isRegularFileKey])
            guard allowed.contains(parent), values.isRegularFile == true else {
              throw CocoaError(.fileReadNoPermission)
            }
            let task = try AttachmentExport(source: source, name: name) { [weak self] success in
              self?.attachmentExport = nil
              result(success)
            }
            self.attachmentExport = task
            var presenter = root
            while let presented = presenter.presentedViewController { presenter = presented }
            presenter.present(task.picker, animated: true)
          } catch {
            result(FlutterError(code: "IO_ERROR", message: "Export unavailable", details: nil))
          }
          return
        }
        guard call.method == "storageFreeBytes" else {
          result(FlutterMethodNotImplemented)
          return
        }
        do {
          let url = URL(fileURLWithPath: NSHomeDirectory())
          let capacity = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
          guard let free = capacity.volumeAvailableCapacityForImportantUsage,
                let total = capacity.volumeTotalCapacity else {
            result(FlutterError(code: "IO_ERROR", message: "Storage unavailable", details: nil))
            return
          }
          result(max(Int64(0), free - Int64(total) / 100))
        } catch {
          result(FlutterError(code: "IO_ERROR", message: "Storage unavailable", details: nil))
        }
      }
      storageChannel = channel
    }
    if let registrar = registrar(forPlugin: "NoNetChatAppleFastLane") {
      AppleFastLanePlugin.register(with: registrar)
    }
    if let registrar = registrar(forPlugin: "NoNetChatHotspot") {
      AppleHotspotPlugin.register(with: registrar)
    }
    if let registrar = registrar(forPlugin: "NoNetChatMaps") {
      let channel = FlutterMethodChannel(name: "nonetchat/maps", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "openPoint" else {
          result(FlutterMethodNotImplemented)
          return
        }
        guard UIApplication.shared.applicationState == .active,
              let args = call.arguments as? [String: Any],
              let latitude = args["latitudeE7"] as? Int,
              let longitude = args["longitudeE7"] as? Int,
              (-900000000...900000000).contains(latitude),
              (-1800000000...1800000000).contains(longitude) else {
          result(false)
          return
        }
        // Open the native Maps app, never a browser or a remote map endpoint.
        let point = CLLocationCoordinate2D(latitude: Double(latitude) / 1e7, longitude: Double(longitude) / 1e7)
        let item = MKMapItem(placemark: MKPlacemark(coordinate: point))
        result(item.openInMaps(launchOptions: nil))
      }
      mapsChannel = channel
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

/// The OS copies a file URL to the user-selected Files provider. A temporary
/// hard link supplies the display name without another file-sized RAM/disk copy.
private final class AttachmentExport: NSObject, UIDocumentPickerDelegate {
  let picker: UIDocumentPickerViewController
  private let directory: URL
  private var completion: ((Bool) -> Void)?
  init(source: URL, name: String, completion: @escaping (Bool) -> Void) throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    directory = temporary
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let cleanName = (name.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
    let target = temporary.appendingPathComponent(cleanName.isEmpty ? "NoNetChat-file" : cleanName)
    do { try FileManager.default.linkItem(at: source, to: target) }
    catch { try? FileManager.default.removeItem(at: temporary); throw error }
    if #available(iOS 14.0, *) {
      picker = UIDocumentPickerViewController(forExporting: [target], asCopy: true)
    } else {
      picker = UIDocumentPickerViewController(url: target, in: .exportToService)
    }
    self.completion = completion
    super.init()
    picker.delegate = self
  }
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(!urls.isEmpty) }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(false) }
  private func finish(_ success: Bool) {
    let callback = completion
    completion = nil
    try? FileManager.default.removeItem(at: directory)
    callback?(success)
  }
}
