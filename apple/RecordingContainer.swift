import Foundation

/// ISO BMFF data references must be self-contained before a native codec sees
/// any bytes. Inspect fixed headers only; never allocate an atom-sized buffer.
enum RecordingContainer {
  static func hasOnlyLocalReferences(_ file: RecordingOutputFile) -> Bool {
    var references = 0, movies = 0, media = 0
    func bytes(_ offset: Int, _ count: Int) -> Data? {
      var data = Data(count: count)
      let read = data.withUnsafeMutableBytes { value -> Int? in
        guard let base = value.baseAddress else { return nil }
        return file.read(at: Int64(offset), into: base, count: count)
      }
      return read == count ? data : nil
    }
    func integer(_ data: Data) -> UInt64 {
      data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    func walk(_ begin: Int, _ end: Int, _ parent: String) -> Bool {
      var offset = begin
      while offset < end {
        guard end - offset >= 8, let header = bytes(offset, 8) else { return false }
        var length = integer(header.prefix(4)), width = 8
        let type = String(decoding: header.suffix(4), as: UTF8.self)
        if length == 1 {
          guard end - offset >= 16, let extended = bytes(offset + 8, 8) else { return false }
          length = integer(extended); width = 16
        } else if length == 0 { length = UInt64(end - offset) }
        guard length >= width, length <= end - offset else { return false }
        let next = offset + Int(length), payload = offset + width
        if parent.isEmpty && type == "moov" { movies += 1 }
        if parent.isEmpty && type == "mdat" { media += 1 }
        let children = ["": "moov", "moov": "trak", "trak": "mdia",
                        "mdia": "minf", "minf": "dinf"]
        if children[parent] == type {
          guard walk(payload, next, type) else { return false }
        } else if parent == "dinf" && type == "dref" {
          guard next - payload >= 8, let full = bytes(payload, 8),
                integer(full.prefix(4)) == 0, integer(full.suffix(4)) == 1,
                next - payload == 20, let entry = bytes(payload + 8, 12),
                integer(entry.prefix(4)) == 12,
                String(decoding: entry[4..<8], as: UTF8.self) == "url ",
                integer(entry.suffix(4)) == 1 else { return false }
          references += 1
        }
        offset = next
      }
      return offset == end
    }
    return file.byteCount > 0 && walk(0, file.byteCount, "") &&
      movies == 1 && media > 0 && references > 0
  }
}
