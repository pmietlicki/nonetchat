import Foundation
import WebRTC

/// The caller supplies the peer map belonging to its actual Flutter plugin.
/// In particular, never obtain it from FlutterWebRTCPlugin.sharedSingleton.
@MainActor enum AppleReceivedAudioSources {
  static func directory(current: @escaping () -> Bool,
                        peer: @escaping (String) -> RTCPeerConnection?) -> ReceivedAudioSources {
    ReceivedAudioSources(current: current, peer: { id in
      peer(id).map(AppleReceivedAudioPeer.init)
    })
  }
}

@MainActor private final class AppleReceivedAudioPeer: ReceivedAudioPeer {
  let peer: RTCPeerConnection
  init(_ peer: RTCPeerConnection) { self.peer = peer }
  var live: Bool {
    peer.signalingState != .closed && peer.connectionState != .closed && peer.connectionState != .failed
  }
  var receivers: [any ReceivedAudioReceiver] {
    peer.receivers.map(AppleReceivedAudioReceiver.init)
  }
  func samePeer(as other: any ReceivedAudioPeer) -> Bool {
    (other as? AppleReceivedAudioPeer)?.peer === peer
  }
}

@MainActor private final class AppleReceivedAudioReceiver: ReceivedAudioReceiver {
  let receiver: RTCRtpReceiver
  init(_ receiver: RTCRtpReceiver) { self.receiver = receiver }
  var id: String { receiver.receiverId }
  var track: (any ReceivedAudioTrack)? {
    (receiver.track as? RTCAudioTrack).map(AppleReceivedAudioTrack.init)
  }
  func sameReceiver(as other: any ReceivedAudioReceiver) -> Bool {
    guard let other = other as? AppleReceivedAudioReceiver else { return false }
    // RTCRtpReceiver::isEqual compares nativeRtpReceiver, including when the
    // public getter created a fresh Objective-C wrapper.
    return receiver.isEqual(other.receiver)
  }
}

@MainActor final class AppleReceivedAudioTrack: ReceivedAudioTrack {
  /// Keep this exact wrapper for addRenderer/removeRenderer. Its _adapters
  /// collection is wrapper-local in the pinned SDK, not process-global.
  let audio: RTCAudioTrack
  init(_ audio: RTCAudioTrack) { self.audio = audio }
  var id: String { audio.trackId }
  var live: Bool { audio.readyState == .live }
  var enabled: Bool { audio.isEnabled }
  func sameSource(as other: any ReceivedAudioTrack) -> Bool {
    guard let other = other as? AppleReceivedAudioTrack else { return false }
    return audio.isEqual(other.audio) // Native track equality, not wrapper ===.
  }
}
