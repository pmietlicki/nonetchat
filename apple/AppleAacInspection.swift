import Foundation
import AudioToolbox

struct AppleAacMetadata: Sendable {
  let bytes: Int, durationUs: Int64, sampleRate: Int, channels: Int
  let firstSampleUs: Int64, secondSampleUs: Int64, endSampleUs: Int64
  var fields: [String: Any] {
    ["codec": "audio/mp4a-latm", "bytes": bytes, "durationUs": durationUs,
     "sampleRate": sampleRate, "channels": channels, "firstSampleUs": firstSampleUs,
     "secondSampleUs": secondSampleUs, "endSampleUs": endSampleUs]
  }
}

struct AppleAacInspectionResult: Sendable {
  let file: RecordingFileClosed
  let metadata: AppleAacMetadata?
}

/// Synchronous worker-only inspection. Apple receives callback bytes from the
/// pinned read-only file, never a URL/path or writable descriptor. Stop fences
/// those reads; SDK and POSIX close must all succeed before metadata is exposed.
enum AppleAacInspection {
  static func read(_ file: RecordingOutputFile) -> AppleAacInspectionResult {
    guard file.prepare(), RecordingContainer.hasOnlyLocalReferences(file) else {
      return AppleAacInspectionResult(file: file.finish(finalized: false), metadata: nil)
    }
    let context = Unmanaged.passRetained(file).toOpaque()
    var audio: AudioFileID?, decoded: ExtAudioFileRef?
    var metadata: AppleAacMetadata?
    let opened = AudioFileOpenWithCallbacks(context, { context, position, requested, buffer, actual in
      actual.pointee = 0
      let file = Unmanaged<RecordingOutputFile>.fromOpaque(context).takeUnretainedValue()
      guard let count = file.read(at: position, into: buffer, count: Int(requested)) else {
        return kAudioFileUnspecifiedError
      }
      actual.pointee = UInt32(count)
      return noErr
    }, nil, { context in
      Int64(Unmanaged<RecordingOutputFile>.fromOpaque(context).takeUnretainedValue().byteCount)
    }, nil, 0, &audio)

    if opened == noErr, let audio,
       ExtAudioFileWrapAudioFileID(audio, false, &decoded) == noErr, let decoded {
      var input = AudioStreamBasicDescription()
      var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      if ExtAudioFileGetProperty(decoded, kExtAudioFileProperty_FileDataFormat, &size, &input) == noErr,
         input.mFormatID == kAudioFormatMPEG4AAC, input.mSampleRate == 16_000,
         input.mChannelsPerFrame == 1, input.mFramesPerPacket == 1024 {
        var format = AudioStreamBasicDescription(mSampleRate: 16_000, mFormatID: kAudioFormatLinearPCM,
          mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
          mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
          mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        if ExtAudioFileSetProperty(decoded, kExtAudioFileProperty_ClientDataFormat, size, &format) == noErr {
          // One AAC-LC access unit (ISO 14496-3) bounds the temporary PCM. Its
          // size is the accepted codec's actual mFramesPerPacket, not file size.
          let capacity = input.mFramesPerPacket
          var buffer = [Int16](repeating: 0, count: Int(capacity))
          var frames: Int64 = 0, valid = true
          buffer.withUnsafeMutableBytes { bytes in
            while valid {
              var requested = capacity
              var list = AudioBufferList(mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1,
                  mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
              let status = ExtAudioFileRead(decoded, &requested, &list)
              guard status == noErr, requested <= capacity,
                    frames <= Int64.max / 1_000_000 - Int64(requested) else {
                valid = false; break
              }
              if requested == 0 { break }
              frames += Int64(requested)
            }
          }
          if valid && frames > 1 {
            metadata = AppleAacMetadata(bytes: file.byteCount,
              durationUs: frames * 1_000_000 / 16_000, sampleRate: 16_000, channels: 1,
              firstSampleUs: 0, secondSampleUs: 1_000_000 / 16_000,
              endSampleUs: (frames - 1) * 1_000_000 / 16_000)
          }
        }
      }
    }
    // ExtAudioFileWrapAudioFileID does not own the underlying AudioFileID.
    // An unsuccessful native close must not free its callback context or FD.
    let decoderClosed = decoded == nil || ExtAudioFileDispose(decoded!) == noErr
    let audioClosed = decoderClosed && (audio == nil || AudioFileClose(audio!) == noErr)
    guard decoderClosed && audioClosed else {
      return AppleAacInspectionResult(file: RecordingFileClosed(released: false, valid: false,
        bytes: file.byteCount), metadata: nil)
    }
    Unmanaged<RecordingOutputFile>.fromOpaque(context).release()
    let closed = file.finish(finalized: metadata != nil)
    return AppleAacInspectionResult(file: closed, metadata: closed.valid ? metadata : nil)
  }
}
