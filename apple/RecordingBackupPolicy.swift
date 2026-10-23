import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Backup metadata only. No recording, file creation, deletion or network API.
/// The native root is derived independently, never granted by a Dart path.
@MainActor final class RecordingBackupPolicy {
  private let support: URL
  private let exclude: (URL) throws -> Void
  private let excluded: (URL) throws -> Bool

  init(support: URL, exclude: @escaping (URL) throws -> Void,
       excluded: @escaping (URL) throws -> Bool) {
    self.support = support.resolvingSymlinksInPath().standardizedFileURL
    self.exclude = exclude
    self.excluded = excluded
  }

  #if os(iOS) || os(macOS)
  static func application() throws -> RecordingBackupPolicy {
    var root = try FileManager.default.url(for: .applicationSupportDirectory,
      in: .userDomainMask, appropriateFor: nil, create: false)
    #if os(macOS)
    // Match path_provider_foundation 2.6.0, including sandboxed macOS apps.
    guard let bundle = Bundle.main.bundleIdentifier, !bundle.isEmpty,
          !bundle.contains("/"), bundle != ".", bundle != ".." else {
      throw CocoaError(.fileReadNoPermission)
    }
    root.appendPathComponent(bundle, isDirectory: true)
    #endif
    return native(support: root)
  }

  static func native(support: URL) -> RecordingBackupPolicy {
    RecordingBackupPolicy(support: support, exclude: { url in
      var target = url
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try target.setResourceValues(values)
    }, excluded: { url in
      var target = url
      target.removeAllCachedResourceValues()
      return try target.resourceValues(forKeys: [.isExcludedFromBackupKey])
        .isExcludedFromBackup == true
    })
  }
  #endif

  /// Each existing directory is opened without following a link and kept open
  /// until after the uncached metadata read. A replaced name never earns proof.
  /// This is not a filesystem lock against another process with our UID.
  func protect(path: String) throws -> String {
    guard !path.contains("\0"), path.hasPrefix("/"),
          URL(fileURLWithPath: path).standardizedFileURL.path == path else {
      throw CocoaError(.fileReadNoPermission)
    }
    let base = support.appendingPathComponent("NoNetChatRecordings", isDirectory: true).path
    guard path == base || path.hasPrefix(base + "/") else {
      throw CocoaError(.fileReadNoPermission)
    }
    let components = path == base ? [] : path.dropFirst(base.count + 1).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard components.count <= 2,
          components.isEmpty || Self.valid(components[0], count: 64, alphabet: "0123456789abcdef"),
          components.count < 2 || Self.valid(components[1], count: 24,
            alphabet: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-") else {
      throw CocoaError(.fileReadNoPermission)
    }
    var handles: [Int32] = []
    defer { for handle in handles.reversed() { _ = close(handle) } }
    let root = open(support.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard root >= 0 else { throw CocoaError(.fileReadNoPermission) }
    handles.append(root)
    var urls = [support]
    for component in ["NoNetChatRecordings"] + components {
      let handle = openat(handles.last!, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard handle >= 0 else { throw CocoaError(.fileReadNoPermission) }
      handles.append(handle)
      urls.append(urls.last!.appendingPathComponent(component, isDirectory: true))
    }
    func unchanged() throws {
      for (handle, url) in zip(handles, urls) {
        var pinned = stat(), named = stat()
        guard fstat(handle, &pinned) == 0, lstat(url.path, &named) == 0,
              (named.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              named.st_dev == pinned.st_dev, named.st_ino == pinned.st_ino else {
          throw CocoaError(.fileReadNoPermission)
        }
      }
    }
    try unchanged()
    // Protect every level, not just the leaf: descendants inherit the policy.
    for url in urls.dropFirst() {
      try exclude(url)
      guard try excluded(url) else { throw CocoaError(.fileWriteUnknown) }
      try unchanged()
    }
    return path
  }

  private static func valid(_ value: String, count: Int, alphabet: String) -> Bool {
    value.utf8.count == count && value.utf8.allSatisfy { alphabet.utf8.contains($0) }
  }
}
