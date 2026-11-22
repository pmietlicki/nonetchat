import Foundation

@main struct RecordingInputFileTest {
  static func box(_ name: String, _ payload: Data) -> Data {
    let size = UInt32(payload.count + 8)
    return Data([UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)]) + Data(name.utf8) + payload
  }
  static func movie(reference: Data = box("url ", Data([0, 0, 0, 1]))) -> Data {
    var data = box("dref", Data([0, 0, 0, 0, 0, 0, 0, 1]) + reference)
    for type in ["dinf", "minf", "mdia", "trak", "moov"] { data = box(type, data) }
    return box("ftyp", Data("isom".utf8)) + data + box("mdat", Data([1, 2, 3]))
  }
  final class Fixture {
    let root: URL, path: URL
    let account = String(repeating: "a", count: 64), id = String(repeating: "b", count: 24)
    init(_ data: Data = movie()) throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
      let leaf = root.appendingPathComponent("NoNetChatRecordings/\(account)/\(id)", isDirectory: true)
      path = leaf.appendingPathComponent("audio.m4a")
      try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
      try Data("{\"version\":1,\"account\":\"\(account)\",\"id\":\"\(id)\",\"binding\":\"\(String(repeating: "c", count: 64))\"}".utf8)
        .write(to: leaf.appendingPathComponent(".owner"))
      try data.write(to: path)
    }
    func input(calls: RecordingOutputFile.Calls = .init()) -> RecordingOutputFile {
      RecordingOutputFile(support: root, path: path.path, accountHash: account,
        id: id, access: .input, backup: { _ in true }, calls: calls)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
  }

  static func main() throws {
    var checks = 0
    func check(_ value: Bool, line: UInt = #line) {
      checks += 1; if !value { fatalError("Input file check failed at \(line)") }
    }
    do {
      let f = try Fixture(), input = f.input()
      let original = try Data(contentsOf: f.path)
      check(input.prepare()); check(!input.append(Data([9])))
      var result = Data(count: original.count)
      let count = result.withUnsafeMutableBytes { input.read(at: 0, into: $0.baseAddress!, count: $0.count) }
      check(count == original.count && result == original)
      check(RecordingContainer.hasOnlyLocalReferences(input))
      check(input.finish(finalized: true).valid)
      check(try Data(contentsOf: f.path) == original)
      print("RECORDING_INPUT_CASE_OK:owned-read-without-write")
    }
    do {
      let reference = box("url ", Data([0, 0, 0, 0]) + Data("https://invalid.example/media".utf8))
      let f = try Fixture(movie(reference: reference)), input = f.input()
      check(input.prepare()); check(!RecordingContainer.hasOnlyLocalReferences(input))
      check(input.finish(finalized: false).released)
      print("RECORDING_INPUT_CASE_OK:external-reference-rejected")
    }
    do {
      let f = try Fixture(box("mdat", Data([1, 2]))), input = f.input()
      check(input.prepare()); check(!RecordingContainer.hasOnlyLocalReferences(input))
      check(input.finish(finalized: false).released)
      print("RECORDING_INPUT_CASE_OK:missing-reference-rejected")
    }
    do {
      let f = try Fixture(Data([0, 0, 0, 1]) + Data("moov".utf8) + Data(repeating: 255, count: 8))
      let input = f.input()
      check(input.prepare()); check(!RecordingContainer.hasOnlyLocalReferences(input))
      check(input.finish(finalized: false).released)
      print("RECORDING_INPUT_CASE_OK:oversized-atom-rejected")
    }
    do {
      let f = try Fixture()
      var calls = RecordingOutputFile.Calls(); calls.sync = { _ in preconditionFailure("Read issued fsync") }
      let input = f.input(calls: calls)
      check(input.prepare()); check(input.finish(finalized: true).valid)
      print("RECORDING_INPUT_CASE_OK:read-only-close")
    }
    do {
      let f = try Fixture(), input = f.input()
      input.retireReads()
      check(!input.prepare()); check(input.finish(finalized: false).released)
      print("RECORDING_INPUT_CASE_OK:retire-before-open")
    }
    do {
      let f = try Fixture(), input = f.input()
      check(input.prepare()); input.retireReads()
      var byte: UInt8 = 0
      check(input.read(at: 0, into: &byte, count: 1) == nil)
      check(input.finish(finalized: false).released)
      print("RECORDING_INPUT_CASE_OK:retire-before-close")
    }
    do {
      let f = try Fixture(), input = f.input()
      check(input.prepare())
      try FileManager.default.moveItem(at: f.path, to: f.path.appendingPathExtension("original"))
      try movie().write(to: f.path)
      var byte: UInt8 = 0
      check(input.read(at: 0, into: &byte, count: 1) == nil)
      check(!input.finish(finalized: true).valid)
      print("RECORDING_INPUT_CASE_OK:replaced-file-rejected")
    }
    do {
      let f = try Fixture(), input = f.input()
      check(input.prepare())
      try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: f.path.path)
      var byte: UInt8 = 0
      check(input.read(at: 0, into: &byte, count: 1) == nil)
      check(!input.finish(finalized: true).valid)
      print("RECORDING_INPUT_CASE_OK:changed-file-rejected")
    }
    do {
      let f = try Fixture(), input = f.input()
      check(input.prepare())
      var byte: UInt8 = 0
      check(input.read(at: -1, into: &byte, count: 1) == nil)
      check(input.read(at: Int64(input.byteCount), into: &byte, count: 1) == 0)
      check(input.finish(finalized: true).valid)
      check(input.read(at: 0, into: &byte, count: 1) == nil)
      print("RECORDING_INPUT_CASE_OK:ranges-and-late-read")
    }
    print("RECORDING_INPUT_OK:\(checks)")
  }
}
