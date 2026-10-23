import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main struct RecordingOutputFileTest {
  final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
  }
  static let checks = Counter()
  static let account = String(repeating: "a", count: 64)
  static let uid = String(repeating: "b", count: 24)
  static func check(_ value: Bool) {
    checks.add()
    precondition(value, "Recording output file assertion failed")
  }
  final class Fixture {
    let root: URL, leaf: URL, path: String
    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
      leaf = root.appendingPathComponent("NoNetChatRecordings/\(account)/\(uid)", isDirectory: true)
      path = leaf.appendingPathComponent("audio.m4a").path
      try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
      try marker().write(to: leaf.appendingPathComponent(".owner"))
    }
    func file(calls: RecordingOutputFile.Calls = .init(),
              backup: @escaping @Sendable (URL) -> Bool = { _ in true }) -> RecordingOutputFile {
      RecordingOutputFile(support: root, path: path, accountHash: account, id: uid, backup: backup, calls: calls)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
  }
  final class Faults: @unchecked Sendable {
    let lock = NSLock()
    var interrupted = false, closes: [Int32] = []
    private var reused: Int32?
    var file: RecordingOutputFile?
    func interruptOnce() -> Bool {
      lock.lock(); defer { lock.unlock() }
      if interrupted { return false }; interrupted = true; return true
    }
    func close(_ fd: Int32, fail: Bool = false) -> Int32 {
      lock.lock(); closes.append(fd); lock.unlock()
      let status = nativeClose(fd)
      if fail { errno = EINTR; return -1 }
      return status
    }
    func closeReusingFirst(_ fd: Int32, sentinel: Int32) -> Int32 {
      lock.lock(); closes.append(fd); let first = closes.count == 1; lock.unlock()
      let status = nativeClose(fd)
      if first {
        check(status == 0 && dup2(sentinel, fd) == fd)
        lock.lock(); reused = fd; lock.unlock()
        errno = EINTR; return -1
      }
      return status
    }
    var reusedFD: Int32? { lock.lock(); defer { lock.unlock() }; return reused }
  }
  static func marker() -> Data {
    Data("{\"version\":1,\"account\":\"\(account)\",\"id\":\"\(uid)\",\"binding\":\"\(String(repeating: "c", count: 64))\"}".utf8)
  }
  static func nativeWrite(_ fd: Int32, _ data: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.write(fd, data, count)
    #else
    return Glibc.write(fd, data, count)
    #endif
  }
  static func nativeClose(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.close(fd)
    #else
    return Glibc.close(fd)
    #endif
  }

  static func main() throws {
    do {
      let f = try Fixture(), file = f.file()
      check(file.prepare()); check(!file.prepare())
      check(file.append(Data("original".utf8)))
      let done = file.finish(finalized: true)
      check(done == .init(released: true, valid: true, bytes: 8))
      check(file.finish(finalized: false) == done)
      check(!file.append(Data("late".utf8)))
      check(try Data(contentsOf: URL(fileURLWithPath: f.path)) == Data("original".utf8))
      let mode = try FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as! NSNumber
      check(mode.intValue & 0o777 == 0o600)
      print("RECORDING_FILE_CASE_OK:owned-output")
    }
    do {
      let f = try Fixture()
      try Data("previous".utf8).write(to: URL(fileURLWithPath: f.path))
      let file = f.file(); check(!file.prepare())
      check(file.finish(finalized: false).released)
      check(try Data(contentsOf: URL(fileURLWithPath: f.path)) == Data("previous".utf8))
      print("RECORDING_FILE_CASE_OK:never-overwrite")
    }
    do {
      let f = try Fixture()
      let foreign = f.root.appendingPathComponent("foreign")
      try Data("keep".utf8).write(to: foreign)
      try FileManager.default.createSymbolicLink(at: URL(fileURLWithPath: f.path), withDestinationURL: foreign)
      let file = f.file(); check(!file.prepare()); check(file.finish(finalized: false).released)
      check(try Data(contentsOf: foreign) == Data("keep".utf8))
      print("RECORDING_FILE_CASE_OK:file-link")
    }
    do {
      let f = try Fixture(), file = f.file(backup: { _ in false })
      check(!file.prepare()); check(file.finish(finalized: true).released)
      check(!FileManager.default.fileExists(atPath: f.path))
      print("RECORDING_FILE_CASE_OK:backup-refusal")
    }
    do {
      let f = try Fixture()
      try Data("{}".utf8).write(to: f.leaf.appendingPathComponent(".owner"))
      let file = f.file(); check(!file.prepare()); check(file.finish(finalized: true).released)
      check(!FileManager.default.fileExists(atPath: f.path))
      let foreign = RecordingOutputFile(support: f.root, path: f.path, accountHash: String(repeating: "d", count: 64), id: uid, backup: { _ in true })
      check(!foreign.prepare()); check(foreign.finish(finalized: true).released)
      print("RECORDING_FILE_CASE_OK:marker-and-account")
    }
    do {
      let f = try Fixture(), file = f.file()
      check(file.prepare()); check(file.append(Data("first".utf8)))
      let moved = f.root.appendingPathComponent("moved")
      try FileManager.default.moveItem(at: f.leaf, to: moved)
      try FileManager.default.createDirectory(at: f.leaf, withIntermediateDirectories: false)
      try Data("replacement".utf8).write(to: URL(fileURLWithPath: f.path))
      check(!file.append(Data("later".utf8)))
      check(file.finish(finalized: true) == .init(released: true, valid: false, bytes: 5))
      check(try Data(contentsOf: URL(fileURLWithPath: f.path)) == Data("replacement".utf8))
      print("RECORDING_FILE_CASE_OK:directory-replacement")
    }
    do {
      let f = try Fixture(), file = f.file()
      check(file.prepare())
      let alias = f.root.appendingPathComponent("alias")
      try FileManager.default.linkItem(at: URL(fileURLWithPath: f.path), to: alias)
      check(!file.append(Data("no".utf8)))
      check(file.finish(finalized: true).released)
      check(try Data(contentsOf: alias).isEmpty)
      print("RECORDING_FILE_CASE_OK:hard-link")
    }
    do {
      let f = try Fixture(), faults = Faults()
      var calls = RecordingOutputFile.Calls()
      calls.write = { fd, data, count in
        if faults.interruptOnce() { errno = EINTR; return -1 }
        return nativeWrite(fd, data, min(2, count))
      }
      let file = f.file(calls: calls)
      check(file.prepare()); check(file.append(Data("complete".utf8)))
      check(file.finish(finalized: true) == .init(released: true, valid: true, bytes: 8))
      check(try Data(contentsOf: URL(fileURLWithPath: f.path)) == Data("complete".utf8))
      print("RECORDING_FILE_CASE_OK:partial-write-and-interruption")
    }
    do {
      let f = try Fixture()
      var calls = RecordingOutputFile.Calls(); calls.write = { _, _, _ in errno = ENOSPC; return -1 }
      let file = f.file(calls: calls); check(file.prepare())
      check(!file.append(Data("missing".utf8)))
      check(file.finish(finalized: true) == .init(released: true, valid: false, bytes: 0))
      print("RECORDING_FILE_CASE_OK:write-failure")
    }
    do {
      let f = try Fixture()
      var calls = RecordingOutputFile.Calls(); calls.sync = { _ in errno = EIO; return -1 }
      let file = f.file(calls: calls); check(file.prepare()); check(file.append(Data("stored".utf8)))
      check(file.finish(finalized: true) == .init(released: true, valid: false, bytes: 6))
      print("RECORDING_FILE_CASE_OK:sync-failure")
    }
    do {
      let f = try Fixture(), faults = Faults()
      var calls = RecordingOutputFile.Calls(); calls.close = { faults.close($0, fail: true) }
      let file = f.file(calls: calls); check(file.prepare()); check(file.append(Data("stored".utf8)))
      let done = file.finish(finalized: true)
      check(done == .init(released: false, valid: false, bytes: 6))
      check(faults.closes.count == 6 && Set(faults.closes).count == 6)
      check(file.finish(finalized: true) == done)
      check(faults.closes.count == 6)
      print("RECORDING_FILE_CASE_OK:uncertain-close-never-retried")
    }
    do {
      let f = try Fixture(), faults = Faults()
      let file = f.file(backup: { _ in
        check(faults.file?.finish(finalized: false).released == true)
        return true
      })
      faults.file = file
      check(!file.prepare()); check(!FileManager.default.fileExists(atPath: f.path))
      check(file.finish(finalized: false).released)
      faults.file = nil
      print("RECORDING_FILE_CASE_OK:retired-during-backup")
    }
    do {
      let f = try Fixture()
      let path = f.leaf.appendingPathComponent("video.mp4").path
      let file = RecordingOutputFile(support: f.root, path: path, accountHash: account,
        id: uid, content: .audioVideo, backup: { _ in true })
      check(file.prepare()); check(file.append(Data("synthetic-container".utf8)))
      check(file.finish(finalized: true) == .init(released: true, valid: true, bytes: 19))
      check(!FileManager.default.fileExists(atPath: f.path))
      let wrong = RecordingOutputFile(support: f.root, path: path, accountHash: account,
        id: uid, content: .audio, backup: { _ in true })
      check(!wrong.prepare()); check(wrong.finish(finalized: false).released)
      print("RECORDING_FILE_CASE_OK:typed-video-name")
    }
    do {
      let f = try Fixture(), file = f.file()
      check(file.prepare()); check(file.append(Data("unchanged".utf8)))
      try marker().dropLast().write(to: f.leaf.appendingPathComponent(".owner"))
      check(!file.append(Data("no".utf8)))
      check(file.finish(finalized: true) == .init(released: true, valid: false, bytes: 9))
      print("RECORDING_FILE_CASE_OK:marker-tampering")
    }
    do {
      let f = try Fixture(), file = f.file()
      check(file.prepare()); check(file.append(Data("unchanged".utf8)))
      try Data().write(to: URL(fileURLWithPath: f.path))
      check(!file.append(Data("no".utf8)))
      check(file.finish(finalized: true) == .init(released: true, valid: false, bytes: 9))
      print("RECORDING_FILE_CASE_OK:output-truncation")
    }
    do {
      let f = try Fixture(), faults = Faults()
      let sentinelURL = f.root.appendingPathComponent("sentinel")
      try Data("preserve".utf8).write(to: sentinelURL)
      let sentinel = open(sentinelURL.path, O_RDONLY | O_CLOEXEC)
      check(sentinel >= 0)
      defer { _ = nativeClose(sentinel); if let reused = faults.reusedFD { _ = nativeClose(reused) } }
      var calls = RecordingOutputFile.Calls()
      calls.close = { faults.closeReusingFirst($0, sentinel: sentinel) }
      var file: RecordingOutputFile? = f.file(calls: calls)
      check(file!.prepare()); check(file!.append(Data("owned".utf8)))
      check(file!.finish(finalized: true) == .init(released: false, valid: false, bytes: 5))
      check(!file!.finish(finalized: true).released)
      file = nil // Destruction must not close the foreign reused descriptor.
      check(faults.closes.count == 6)
      guard let reused = faults.reusedFD else { preconditionFailure("Missing reused descriptor") }
      var bytes = [UInt8](repeating: 0, count: 8)
      check(pread(reused, &bytes, bytes.count, 0) == bytes.count)
      check(Data(bytes) == Data("preserve".utf8))
      print("RECORDING_FILE_CASE_OK:foreign-fd-reuse-survives")
    }
    do {
      let f = try Fixture()
      let moved = f.root.appendingPathComponent("linked-leaf")
      try FileManager.default.moveItem(at: f.leaf, to: moved)
      try FileManager.default.createSymbolicLink(at: f.leaf, withDestinationURL: moved)
      let file = f.file(); check(!file.prepare()); check(file.finish(finalized: true).released)
      check(!FileManager.default.fileExists(atPath: moved.appendingPathComponent("audio.m4a").path))
      print("RECORDING_FILE_CASE_OK:directory-link")
    }
    do {
      let f = try Fixture()
      let owner = f.leaf.appendingPathComponent(".owner")
      let moved = f.root.appendingPathComponent("linked-marker")
      try FileManager.default.moveItem(at: owner, to: moved)
      try FileManager.default.createSymbolicLink(at: owner, withDestinationURL: moved)
      let file = f.file(); check(!file.prepare()); check(file.finish(finalized: true).released)
      check(!FileManager.default.fileExists(atPath: f.path))
      print("RECORDING_FILE_CASE_OK:marker-link")
    }
    do {
      let f = try Fixture()
      let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
      let writeDone = DispatchSemaphore(value: 0), closeStarted = DispatchSemaphore(value: 0), closeDone = DispatchSemaphore(value: 0)
      var calls = RecordingOutputFile.Calls()
      calls.write = { fd, data, count in
        entered.signal(); release.wait()
        return nativeWrite(fd, data, count)
      }
      let file = f.file(calls: calls); check(file.prepare())
      DispatchQueue.global().async {
        check(file.append(Data("concurrent-tail".utf8)))
        writeDone.signal()
      }
      entered.wait()
      DispatchQueue.global().async {
        closeStarted.signal()
        check(file.finish(finalized: true) == .init(released: true, valid: true, bytes: 15))
        closeDone.signal()
      }
      closeStarted.wait()
      check(closeDone.wait(timeout: .now()) == .timedOut)
      release.signal(); writeDone.wait(); closeDone.wait()
      check(!file.append(Data("late".utf8)))
      check(try Data(contentsOf: URL(fileURLWithPath: f.path)) == Data("concurrent-tail".utf8))
      print("RECORDING_FILE_CASE_OK:concurrent-close-drains-write")
    }
    print("RECORDING_FILE_OK:\(checks.value)")
  }
}
