import Flutter
import UIKit
import UserNotifications
import MapKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var notificationActions: NotificationActions?
  private var localMedia: AppleLocalMediaPlugin?
  private var mapsChannel: FlutterMethodChannel?
  private var storageChannel: FlutterMethodChannel?
  private var attachmentExport: AttachmentExport?
  private var lockWindowChannel: FlutterMethodChannel?
  private var protectLockWindow = UserDefaults.standard.bool(forKey: "flutter.application_lock_enabled")
  private var lockWindowCover: UIView?
  private var lockWindowTicket: String?
  private weak var lockWindowOwner: UIWindow?
  private var lockWindowIdentity = UUID().uuidString

  override func applicationWillResignActive(_ application: UIApplication) {
    coverLockWindow()
    super.applicationWillResignActive(application)
  }

  private func coverLockWindow() {
    guard protectLockWindow, let original = window else { return }
    lockWindowCover?.removeFromSuperview()
    let cover = UIView(frame: original.bounds)
    cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    cover.backgroundColor = .systemBackground
    cover.accessibilityViewIsModal = true
    original.addSubview(cover)
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
      case "identity":
        guard let original = self.window else { result(nil); return }
        if original !== self.lockWindowOwner {
          self.lockWindowOwner = original
          self.lockWindowIdentity = UUID().uuidString
        }
        result(self.lockWindowIdentity)
      case "setProtected":
        guard let args = call.arguments as? [String: Any],
              args["window"] as? String == self.lockWindowIdentity,
              let value = args["enabled"] as? Bool,
              let window = self.window, window === self.lockWindowOwner else {
          result(false); return
        }
        self.protectLockWindow = value
        if !value { self.removeLockWindowCover() }
        else if UIApplication.shared.applicationState != .active { self.coverLockWindow() }
        result(true)
      case "paintTicket":
        guard self.lockWindowCover?.superview === self.window else { result(nil); return }
        result(self.lockWindowTicket)
      case "painted":
        guard UIApplication.shared.applicationState == .active,
              let ticket = call.arguments as? String, ticket == self.lockWindowTicket,
              self.lockWindowCover?.superview === self.window else { result(false); return }
        self.removeLockWindowCover()
        result(true)
      default: result(FlutterMethodNotImplemented)
      }
    }
    lockWindowChannel = channel
  }

  override func userNotificationCenter(_ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    if response.notification.request.content.userInfo["nonetLocalMedia"] as? String == "v1" {
      localMedia?.presentation.receive(response)
      completionHandler()
    } else if NotificationActions.owns(response), let actions = notificationActions {
      actions.receive(response, completion: completionHandler)
    } else {
      super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
    }
  }
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let receivedAudio = AppleWebRTCRegistration.register(in: self) {
      GeneratedPluginRegistrant.register(with: $0)
    }
    if let registrar = registrar(forPlugin: "NoNetChatNotificationActions") {
      UNUserNotificationCenter.current().delegate = self
      notificationActions = NotificationActions(messenger: registrar.messenger())
      if let actions = notificationActions {
        localMedia = AppleLocalMediaPlugin(messenger: registrar.messenger(), actions: actions,
          receivedAudio: receivedAudio)
      }
    }
    if let registrar = registrar(forPlugin: "NoNetChatLockWindow") {
      registerLockWindow(registrar.messenger())
    }
    if let registrar = registrar(forPlugin: "NoNetChatStorage") {
      let channel = FlutterMethodChannel(name: "com.nonetchat/native_utils", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { [weak self] call, result in
        if DeferredPrekeyFiles.handles(call.method) {
          DeferredPrekeyFiles.handle(call, result)
          return
        }
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
            let task = try AttachmentExport(source: source, name: name) { [weak self] outcome in
              self?.attachmentExport = nil
              switch outcome {
              case .success(let saved):
                result(saved)
              case .failure:
                result(FlutterError(code: "IO_ERROR", message: "Export cleanup unavailable", details: nil))
              }
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
        if call.method == "privateTemporaryDirectory" {
          let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
          let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
          guard let self, self.attachmentExport == nil,
                temporary.path.hasPrefix(home.path + "/") else {
            result(FlutterError(code: "IO_ERROR", message: "Temporary storage unavailable", details: nil))
            return
          }
          result(temporary.path)
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
  private var completion: ((Result<Bool, Error>) -> Void)?
  init(source: URL, name: String, completion: @escaping (Result<Bool, Error>) -> Void) throws {
    let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    guard root.path.hasPrefix(home.path + "/") else {
      throw CocoaError(.fileWriteNoPermission)
    }
    try Self.removeAbandoned(in: root)
    let temporary = root.appendingPathComponent("nonet-export-" + UUID().uuidString, isDirectory: true)
    directory = temporary
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
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
  private static func removeAbandoned(in root: URL) throws {
    let manager = FileManager.default
    for entry in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
      let name = entry.lastPathComponent
      let prefix = "nonet-export-"
      guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { continue }
      let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw CocoaError(.fileWriteNoPermission)
      }
      try removeConfirmed(entry, manager: manager)
    }
  }

  private static func removeConfirmed(_ directory: URL, manager: FileManager) throws {
    try manager.removeItem(at: directory)
    let parent = directory.deletingLastPathComponent()
    guard !((try manager.contentsOfDirectory(atPath: parent.path)).contains(directory.lastPathComponent)) else {
      throw CocoaError(.fileWriteUnknown)
    }
  }

  private func finish(_ success: Bool) {
    guard let callback = completion else { return }
    completion = nil
    do {
      try Self.removeConfirmed(directory, manager: FileManager.default)
      callback(.success(success))
    } catch {
      callback(.failure(error))
    }
  }
}
