import Foundation
#if os(iOS) && !NONETCHAT_PREKEY_FILES_STANDALONE
import Flutter
#elseif os(macOS) && !NONETCHAT_PREKEY_FILES_STANDALONE
import FlutterMacOS
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Owns only the fixed directory of encrypted prekey slots. Dart never grants
/// a path, creates a directory or supplies keys to this native boundary.
struct DeferredPrekeyFiles {
  private static let directory = "NoNetChatDeferredPrekeys"
  private static let fileLength = 73
  private let support: URL
  private let protection: (URL, Bool) throws -> Void

  init(support: URL, protection: @escaping (URL, Bool) throws -> Void) {
    self.support = support.resolvingSymlinksInPath().standardizedFileURL
    self.protection = protection
  }

  #if os(iOS) || os(macOS)
  @MainActor static func application() throws -> Self {
    let root = try RecordingBackupPolicy.applicationSupportDirectory()
      .resolvingSymlinksInPath().standardizedFileURL
    let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
    guard root.path.hasPrefix(home.path + "/") else { throw CocoaError(.fileReadNoPermission) }
    return Self(support: root) { url, write in
      var target = url
      if write {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes(
          [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
          ofItemAtPath: target.path)
        #endif
      }
      target.removeAllCachedResourceValues()
      let values = try target.resourceValues(forKeys: [.isExcludedFromBackupKey])
      guard values.isExcludedFromBackup == true else { throw CocoaError(.fileWriteUnknown) }
      #if os(iOS)
      let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
      guard attributes[.protectionKey] as? FileProtectionType ==
        .completeUntilFirstUserAuthentication else { throw CocoaError(.fileWriteUnknown) }
      #endif
    }
  }

  #if !NONETCHAT_PREKEY_FILES_STANDALONE
  private static let queue = DispatchQueue(label: "fr.pmietlicki.nonetchat.deferred-prekeys")

  static func handles(_ method: String) -> Bool {
    ["prepareDeferredPrekeyFiles", "storeDeferredPrekeyFile", "readDeferredPrekeyFile",
     "removeDeferredPrekeyFile", "eraseDeferredPrekeyFiles"].contains(method)
  }

  @MainActor static func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let original: Self
    do { original = try application() }
    catch { result(channelError); return }
    let method = call.method
    let args = call.arguments as? [String: Any]
    let slot = args?["slot"] as? String ?? ""
    let payload = (args?["bytes"] as? FlutterStandardTypedData)?.data
    queue.async {
      do {
        let value: Any?
        switch method {
        case "prepareDeferredPrekeyFiles":
          value = try original.prepare()
        case "storeDeferredPrekeyFile":
          guard let payload else { throw CocoaError(.fileWriteUnknown) }
          try original.store(slot: slot, bytes: payload)
          value = nil
        case "readDeferredPrekeyFile":
          value = try original.read(slot: slot).map { FlutterStandardTypedData(bytes: $0) }
        case "removeDeferredPrekeyFile":
          try original.remove(slot: slot)
          value = nil
        case "eraseDeferredPrekeyFiles":
          try original.erase()
          value = nil
        default:
          throw CocoaError(.fileReadNoPermission)
        }
        DispatchQueue.main.async { result(value) }
      } catch {
        DispatchQueue.main.async { result(channelError) }
      }
    }
  }

  private static var channelError: FlutterError {
    FlutterError(code: "IO_ERROR", message: "Secure storage unavailable", details: nil)
  }
  #endif
  #endif

  /// A recreated directory cannot contain keys from a restored SQLite catalog.
  func prepare() throws -> Bool {
    let existed = try withDirectory(create: false, verifyProtection: false) { _, _ in true } ?? false
    _ = try withDirectory(create: true) { _, _ in true }
    return existed
  }

  func store(slot: String, bytes: Data) throws {
    guard Self.validSlot(slot), bytes.count == Self.fileLength else {
      throw CocoaError(.fileWriteUnknown)
    }
    let stored = try withDirectory(create: false) { directory, path in
      let descriptor = openat(directory, slot, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                              mode_t(S_IRUSR | S_IWUSR))
      guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
      let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
      defer { _ = close(descriptor) }
      let url = path.appendingPathComponent(slot, isDirectory: false)
      try Self.sameFile(descriptor, at: url, expected: mode_t(S_IFREG))
      try protection(url, true)
      try Self.sameFile(descriptor, at: url, expected: mode_t(S_IFREG))
      try file.write(contentsOf: bytes)
      guard fsync(descriptor) == 0, fsync(directory) == 0 else {
        throw CocoaError(.fileWriteUnknown)
      }
      try Self.sameFile(descriptor, at: url, expected: mode_t(S_IFREG))
      try protection(url, false)
      try Self.sameFile(descriptor, at: url, expected: mode_t(S_IFREG))
      return true
    }
    guard stored == true else { throw CocoaError(.fileNoSuchFile) }
  }

  func read(slot: String) throws -> Data? {
    guard Self.validSlot(slot) else { throw CocoaError(.fileReadNoPermission) }
    let stored: Data?? = try withDirectory(create: false) { directory, path -> Data? in
      let descriptor = openat(directory, slot, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      if descriptor < 0 && errno == ENOENT { return nil }
      guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
      let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
      defer { _ = close(descriptor) }
      let url = path.appendingPathComponent(slot, isDirectory: false)
      try Self.sameFile(descriptor, at: url, expected: mode_t(S_IFREG))
      try protection(url, false)
      guard let data = try file.read(upToCount: Self.fileLength + 1),
            data.count == Self.fileLength else { throw CocoaError(.fileReadCorruptFile) }
      try Self.sameFile(descriptor, at: url, expected: mode_t(S_IFREG))
      return data
    }
    return stored ?? nil
  }

  func remove(slot: String) throws {
    guard Self.validSlot(slot) else { throw CocoaError(.fileWriteUnknown) }
    _ = try withDirectory(create: false) { directory, _ in
      try Self.unlink(slot: slot, directory: directory)
    }
  }

  func erase() throws {
    _ = try withDirectory(create: false, verifyProtection: false) { directory, path in
      let manager = FileManager.default
      for slot in try manager.contentsOfDirectory(atPath: path.path) {
        guard Self.validSlot(slot) else { throw CocoaError(.fileWriteUnknown) }
        try Self.unlink(slot: slot, directory: directory)
      }
      guard try manager.contentsOfDirectory(atPath: path.path).isEmpty else {
        throw CocoaError(.fileWriteUnknown)
      }
    }
  }

  private func withDirectory<T>(create: Bool, verifyProtection: Bool = true,
                                _ action: (Int32, URL) throws -> T) throws -> T? {
    let parent = open(support.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw CocoaError(.fileReadNoPermission) }
    defer { _ = close(parent) }
    if create && mkdirat(parent, Self.directory, mode_t(S_IRWXU)) != 0 && errno != EEXIST {
      throw CocoaError(.fileWriteUnknown)
    }
    let directory = openat(parent, Self.directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    if directory < 0 && errno == ENOENT && !create { return nil }
    guard directory >= 0 else { throw CocoaError(.fileReadNoPermission) }
    defer { _ = close(directory) }
    let url = support.appendingPathComponent(Self.directory, isDirectory: true)
    func unchanged() throws {
      try Self.sameFile(parent, at: support, expected: mode_t(S_IFDIR))
      try Self.sameFile(directory, at: url, expected: mode_t(S_IFDIR))
    }
    try unchanged()
    if verifyProtection { try protection(url, create) }
    try unchanged()
    if create && (fsync(directory) != 0 || fsync(parent) != 0) {
      throw CocoaError(.fileWriteUnknown)
    }
    let result = try action(directory, url)
    try unchanged()
    return result
  }

  private static func sameFile(_ descriptor: Int32, at url: URL, expected: mode_t) throws {
    var pinned = stat(), named = stat()
    guard fstat(descriptor, &pinned) == 0, lstat(url.path, &named) == 0,
          (named.st_mode & mode_t(S_IFMT)) == expected,
          named.st_dev == pinned.st_dev, named.st_ino == pinned.st_ino,
          expected != mode_t(S_IFREG) || pinned.st_nlink == 1 && named.st_nlink == 1 else {
      throw CocoaError(.fileReadNoPermission)
    }
  }

  private static func unlink(slot: String, directory: Int32) throws {
    var entry = stat()
    if fstatat(directory, slot, &entry, AT_SYMLINK_NOFOLLOW) == 0 {
      guard (entry.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
            entry.st_nlink == 1,
            unlinkat(directory, slot, 0) == 0 else { throw CocoaError(.fileWriteUnknown) }
    } else if errno != ENOENT {
      throw CocoaError(.fileWriteUnknown)
    }
    guard fstatat(directory, slot, &entry, AT_SYMLINK_NOFOLLOW) != 0,
          errno == ENOENT, fsync(directory) == 0 else { throw CocoaError(.fileWriteUnknown) }
  }

  private static func validSlot(_ slot: String) -> Bool {
    slot.utf8.count == 64 && slot.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}
