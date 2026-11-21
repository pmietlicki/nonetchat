import Foundation

@main @MainActor struct RecordingBackupTest {
  static var assertions = 0
  static let account = String(repeating: "a", count: 64)
  static let uid = String(repeating: "B", count: 24)

  static func check(_ condition: @autoclosure () -> Bool) {
    assertions += 1
    precondition(condition(), "Recording backup check failed")
  }
  static func fails(_ operation: () throws -> Void) {
    do { try operation(); preconditionFailure("Unsafe backup operation admitted") }
    catch { assertions += 1 }
  }
  static func fixture(_ run: (URL, URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("nonet-backup-" + UUID().uuidString, isDirectory: true)
    let leaf = root.appendingPathComponent("NoNetChatRecordings/" + account + "/" + uid, isDirectory: true)
    try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try run(root, leaf)
  }
  static func marker(_ name: String) { print("RECORDING_BACKUP_CASE_OK:" + name) }

  static func main() throws {
    try fixture { root, leaf in
      var writes = 0
      let policy = RecordingBackupPolicy(support: root, exclude: { _ in writes += 1 }, excluded: { _ in true })
      let base = root.appendingPathComponent("NoNetChatRecordings").path
      for value in [root.path, root.path + "/other", base + "-foreign", leaf.path + "/audio.m4a",
                    base + "/../foreign", base + "/" + String(repeating: "a", count: 63),
                    base + "/" + String(repeating: "A", count: 64),
                    leaf.path + "/", leaf.path + "/..", "relative", leaf.path + "\0"] {
        fails { _ = try policy.protect(path: value) }
      }
      check(writes == 0)
      marker("scope")
    }
    try fixture { root, leaf in
      var written: [String] = []
      let policy = RecordingBackupPolicy(support: root, exclude: { written.append($0.path) },
        excluded: { written.contains($0.path) })
      let result = try policy.protect(path: leaf.path)
      check(result == leaf.path)
      check(written.count == 3)
      check(!written.contains(root.path))
      written.removeAll()
      _ = try policy.protect(path: leaf.deletingLastPathComponent().path)
      check(written.count == 2)
      marker("levels")
    }
    try fixture { root, leaf in
      let before = try FileManager.default.contentsOfDirectory(atPath: leaf.path)
      let broken = RecordingBackupPolicy(support: root, exclude: { _ in throw CocoaError(.fileWriteNoPermission) },
        excluded: { _ in true })
      fails { _ = try broken.protect(path: leaf.path) }
      let missing = RecordingBackupPolicy(support: root, exclude: { _ in }, excluded: { _ in false })
      fails { _ = try missing.protect(path: leaf.path) }
      let unreadable = RecordingBackupPolicy(support: root, exclude: { _ in },
        excluded: { _ in throw CocoaError(.fileReadUnknown) })
      fails { _ = try unreadable.protect(path: leaf.path) }
      let after = try FileManager.default.contentsOfDirectory(atPath: leaf.path)
      check(before == after)
      marker("failures")
    }
    try fixture { root, leaf in
      let saved = root.appendingPathComponent("retained")
      try FileManager.default.moveItem(at: leaf, to: saved)
      try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: saved)
      var writes = 0
      let policy = RecordingBackupPolicy(support: root, exclude: { _ in writes += 1 }, excluded: { _ in true })
      fails { _ = try policy.protect(path: leaf.path) }
      check(writes == 0)
      check(FileManager.default.fileExists(atPath: saved.path))
      marker("links")
    }
    try fixture { root, leaf in
      let saved = root.appendingPathComponent("retained")
      var replaced = false
      let policy = RecordingBackupPolicy(support: root, exclude: { _ in
        if !replaced {
          replaced = true
          try FileManager.default.moveItem(at: leaf, to: saved)
          try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: false)
        }
      }, excluded: { _ in true })
      fails { _ = try policy.protect(path: leaf.path) }
      check(FileManager.default.fileExists(atPath: saved.path))
      check(FileManager.default.fileExists(atPath: leaf.path))
      marker("replacement")
    }
    #if os(macOS) || os(iOS)
    try fixture { root, leaf in
      _ = try RecordingBackupPolicy.native(support: root).protect(path: leaf.path)
      var url = leaf
      url.removeAllCachedResourceValues()
      let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
      check(values.isExcludedFromBackup == true)
      let parentValues = try leaf.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
      check(parentValues.isExcludedFromBackup == true)
    }
    marker("native-policy")
    #else
    // This marker explicitly differs; Linux never claims the Apple OS flag.
    marker("native-policy-pending")
    #endif
    print("RECORDING_BACKUP_OK:\(assertions)")
  }
}
