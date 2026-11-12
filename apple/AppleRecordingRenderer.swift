import AVFoundation
import WebRTC

/// A copy-only RTCAudioRenderer. Never encodes, touches a file or dispatches to
/// the UI from WebRTC's audio callback. Its owner seals the queue BEFORE removing
/// this renderer from the ORIGINAL RTCAudioTrack wrapper, then drains the worker.
final class AppleRecordingRenderer: NSObject, RTCAudioRenderer, @unchecked Sendable {
  let queue: RecordingPcmQueue
  init(queue: RecordingPcmQueue) { self.queue = queue; super.init() }

  func render(pcmBuffer: AVAudioPCMBuffer) {
    let format = pcmBuffer.format
    let sampleRate = format.sampleRate
    let channels = Int(format.channelCount), frames = Int(pcmBuffer.frameLength)
    // Actual SDK RTCAudioRendererAdapter::OnData creates interleaved PCM16.
    // Validate at this native boundary, before integer conversion or memory read.
    guard format.commonFormat == .pcmFormatInt16, format.isInterleaved,
          sampleRate.isFinite, sampleRate >= 1, sampleRate <= Double(Int32.max),
          sampleRate.rounded(.towardZero) == sampleRate,
          channels == 1 || channels == 2, frames > 0,
          frames <= RecordingPcmQueue.maxBytes / (channels * MemoryLayout<Int16>.size) else {
      queue.rejectInvalidInput(); return
    }
    let list = pcmBuffer.audioBufferList.pointee
    let buffer = list.mBuffers
    let needed = frames * channels * MemoryLayout<Int16>.size
    guard list.mNumberBuffers == 1, buffer.mNumberChannels == channels,
          Int(buffer.mDataByteSize) >= needed, let data = buffer.mData else {
      queue.rejectInvalidInput(); return
    }
    _ = queue.push(data, bits: 16, rate: Int(sampleRate), channels: channels, frames: frames)
  }
}
