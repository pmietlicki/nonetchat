import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct RecordingFileClosed: Equatable, Sendable {
  let released: Bool
  /// Byte-stream finalization only. A codec inspector must still establish
  /// media/container validity before this file can enter playable history.
  let valid: Bool
  let bytes: Int
}

enum RecordingFileContent: Sendable {
  case audio, audioVideo
  var filename: String { self == .audio ? "audio.m4a" : "video.mp4" }
}

/// Independent of Flutter/WebRTC. Every mutable field and syscall is protected
/// by lock; injected calls must preserve the same synchronous POSIX semantics.
/// No SDK sees this descriptor. An uncertain close is never retried: the
/// descriptor number may already have been reused by another thread.
final class RecordingOutputFile: @unchecked Sendable {
  struct Calls: Sendable {
    var write: @Sendable (Int32, UnsafeRawPointer, Int) -> Int = { fd, data, count in
      #if canImport(Darwin)
      return Darwin.write(fd, data, count)
      #else
      return Glibc.write(fd, data, count)
      #endif
    }
    var sync: @Sendable (Int32) -> Int32 = { fsync($0) }
    var close: @Sendable (Int32) -> Int32 = {
      #if canImport(Darwin)
      return Darwin.close($0)
      #else
      return Glibc.close($0)
      #endif
    }
  }

  private struct Pin {
    let fd: Int32
    let url: URL
    let identity: stat
    let directory: Bool
  }
  private let lock = NSLock()
  private let support: URL
  private let path: String, account: String, id: String
  let content: RecordingFileContent
  private let backup: @Sendable (URL) -> Bool
  private let calls: Calls
  private var pins: [Pin] = []
  private var marker: Data?
  private var markerFD: Int32?
  private var outputFD: Int32?
  private var attempted = false, sealed = false, failed = false, uncertain = false
  private var created = false, count = 0
  private var result: RecordingFileClosed?

  init(support: URL, path: String, accountHash: String, id: String,
       content: RecordingFileContent = .audio,
       backup: @escaping @Sendable (URL) -> Bool, calls: Calls = Calls()) {
    self.support = support.resolvingSymlinksInPath().standardizedFileURL
    self.path = path; account = accountHash; self.id = id
    self.content = content
    self.backup = backup; self.calls = calls
  }

  /// Exactly one acquisition attempt. Even failed partial acquisition remains
  /// owned by this instance until finish() has closed every acquired handle.
  func prepare() -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard !attempted, !sealed else { return false }
    attempted = true
    guard support.isFileURL, Self.valid(account, count: 64, alphabet: "0123456789abcdef"),
          Self.valid(id, count: 24, alphabet: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"),
          !path.contains("\0") else { failed = true; return false }
    let directory = support.appendingPathComponent("NoNetChatRecordings", isDirectory: true)
      .appendingPathComponent(account, isDirectory: true).appendingPathComponent(id, isDirectory: true)
    guard path == directory.appendingPathComponent(content.filename).path else { failed = true; return false }
    guard pin(open(support.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC),
              at: support, directory: true) else { failed = true; return false }
    var current = support
    for component in ["NoNetChatRecordings", account, id] {
      current.appendPathComponent(component, isDirectory: true)
      guard let parent = pins.last?.fd,
            pin(openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC),
                at: current, directory: true) else { failed = true; return false }
    }
    guard let parent = pins.last?.fd, unchanged() else { failed = true; return false }
    // The metadata verifier may invoke application code in a fake/native
    // adapter. Allow retirement during it, then revalidate the original pins.
    lock.unlock()
    let protected = backup(directory)
    lock.lock()
    guard !sealed, protected, unchanged(),
          pin(openat(parent, ".owner", O_RDONLY | O_NOFOLLOW | O_CLOEXEC),
              at: directory.appendingPathComponent(".owner"), directory: false) else {
      failed = true; return false
    }
    markerFD = pins.last?.fd
    guard let bytes = readMarker(), Self.marker(bytes, account: account, id: id) else {
      failed = true; return false
    }
    marker = bytes
    guard unchanged(),
          pin(openat(parent, content.filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)),
              at: directory.appendingPathComponent(content.filename), directory: false) else {
      failed = true; return false
    }
    outputFD = pins.last?.fd
    created = true
    guard let fd = outputFD, fchmod(fd, mode_t(0o600)) == 0,
          unchanged(), readMarker() == marker else { failed = true; return false }
    return true
  }

  /// Called only by the encoder worker/delegate, never the RTP callback. The
  /// lock covers validation and every partial write, so finish cannot overtake.
  func append(_ data: Data) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard !sealed, !failed, created, let fd = outputFD else { return false }
    guard !data.isEmpty, data.count <= Int.max - count,
          unchanged(), readMarker() == marker else { failed = true; return false }
    let written = data.withUnsafeBytes { bytes -> Bool in
      guard let base = bytes.baseAddress else { return false }
      var offset = 0
      while offset < bytes.count {
        let size = calls.write(fd, base.advanced(by: offset), bytes.count - offset)
        if size < 0, errno == EINTR { continue } // No bytes were transferred.
        guard size > 0, size <= bytes.count - offset else { return false }
        offset += size
        count += size
      }
      return true
    }
    let intact = written && unchanged() && readMarker() == marker
    if !intact { failed = true }
    return intact
  }

  func finish(finalized: Bool) -> RecordingFileClosed {
    lock.lock(); defer { lock.unlock() }
    if let result { return result }
    sealed = true
    // Content failure is separate from resource release. A short/failed file
    // can be deleted after positive closure, but cannot become playable.
    if !finalized || !created || count == 0 || !unchanged() || readMarker() != marker { failed = true }
    if let fd = outputFD, calls.sync(fd) != 0 { failed = true }
    outputFD = nil; markerFD = nil
    for pinned in pins.reversed() {
      if calls.close(pinned.fd) != 0 { uncertain = true }
    }
    // No later code, including deinit, may touch one of these integer handles.
    pins.removeAll()
    let done = RecordingFileClosed(released: !uncertain, valid: !uncertain && !failed, bytes: count)
    result = done
    return done
  }

  private func pin(_ fd: Int32, at url: URL, directory: Bool) -> Bool {
    guard fd >= 0 else { return false }
    var identity = stat()
    guard fstat(fd, &identity) == 0 else {
      if calls.close(fd) != 0 { uncertain = true }
      return false
    }
    pins.append(Pin(fd: fd, url: url, identity: identity, directory: directory))
    let kind = identity.st_mode & mode_t(S_IFMT)
    return kind == mode_t(directory ? S_IFDIR : S_IFREG) && (directory || identity.st_nlink == 1)
  }

  private func unchanged() -> Bool {
    for p in pins {
      var handle = stat(), name = stat()
      guard fstat(p.fd, &handle) == 0, lstat(p.url.path, &name) == 0,
            handle.st_dev == p.identity.st_dev, handle.st_ino == p.identity.st_ino,
            name.st_dev == handle.st_dev, name.st_ino == handle.st_ino,
            (name.st_mode & mode_t(S_IFMT)) == mode_t(p.directory ? S_IFDIR : S_IFREG),
            p.directory || (name.st_nlink == 1 && handle.st_nlink == 1) else { return false }
      if p.fd == outputFD, handle.st_size != count { return false }
    }
    return true
  }

  private func readMarker() -> Data? {
    guard let fd = markerFD else { return nil }
    // Exact same bounded representation as Windows CheckMarker; do not parse
    // arbitrary JSON or add a guessed length allowance to this local marker.
    let prefix = "{\"version\":1,\"account\":\"\(account)\",\"id\":\"\(id)\",\"binding\":\""
    let length = prefix.utf8.count + 64 + 2
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_size == length else { return nil }
    var data = Data(count: length)
    let complete = data.withUnsafeMutableBytes { bytes -> Bool in
      guard let base = bytes.baseAddress else { return false }
      var offset = 0
      while offset < bytes.count {
        let size = pread(fd, base.advanced(by: offset), bytes.count - offset, off_t(offset))
        if size < 0, errno == EINTR { continue }
        guard size > 0, size <= bytes.count - offset else { return false }
        offset += size
      }
      return true
    }
    return complete ? data : nil
  }

  private static func marker(_ data: Data, account: String, id: String) -> Bool {
    let prefix = Data("{\"version\":1,\"account\":\"\(account)\",\"id\":\"\(id)\",\"binding\":\"".utf8)
    guard data.count == prefix.count + 64 + 2, data.prefix(prefix.count) == prefix,
          data.suffix(2) == Data("\"}".utf8) else { return false }
    return data.dropFirst(prefix.count).prefix(64).allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  private static func valid(_ value: String, count: Int, alphabet: String) -> Bool {
    value.utf8.count == count && value.utf8.allSatisfy { alphabet.utf8.contains($0) }
  }

  deinit {
    // Last resort only; never returns a release proof and never retries one
    // of the uncertain descriptors already consumed by explicit finish.
    for p in pins.reversed() { _ = calls.close(p.fd) }
  }
}
