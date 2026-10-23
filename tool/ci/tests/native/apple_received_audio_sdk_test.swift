import Foundation
import WebRTC

/// Real pinned SDK objects, no SDP, microphone, renderer, output or network.
@main @MainActor struct AppleReceivedAudioSDKTest {
  static var checks = 0
  static func check(_ value: @autoclosure () -> Bool) {
    checks += 1
    precondition(value(), "Pinned Apple receiver check failed")
  }
  static func main() {
    check(CommandLine.arguments.count == 2)
    guard let image = Bundle(for: RTCPeerConnectionFactory.self).executableURL else {
      preconditionFailure("Pinned framework image unavailable")
    }
    check(image.resolvingSymlinksInPath().path == URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath().path)
    print("APPLE_RECEIVED_SDK_CASE_OK:pinned-runtime")
    check(RTCInitializeSSL())
    autoreleasepool {
      let factory = RTCPeerConnectionFactory()
      let configuration = RTCConfiguration()
      configuration.sdpSemantics = .unifiedPlan
      let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
      guard let peer = factory.peerConnection(with: configuration, constraints: constraints, delegate: nil),
            let other = factory.peerConnection(with: configuration, constraints: constraints, delegate: nil) else {
        preconditionFailure("Pinned SDK peers unavailable")
      }
      defer { peer.close(); other.close() }
      let options = RTCRtpTransceiverInit()
      options.direction = .recvOnly
      guard let transceiver = peer.addTransceiver(of: .audio, init: options),
            let audio = transceiver.receiver.track as? RTCAudioTrack else {
        preconditionFailure("Receive-only audio source unavailable")
      }
      let first = peer.receivers.filter { $0.receiverId == transceiver.receiver.receiverId }
      let second = peer.receivers.filter { $0.receiverId == transceiver.receiver.receiverId }
      check(first.count == 1 && second.count == 1)
      check(first[0] !== second[0] && first[0].isEqual(second[0]))
      guard let firstTrack = first[0].track as? RTCAudioTrack,
            let secondTrack = second[0].track as? RTCAudioTrack else {
        preconditionFailure("Pinned audio wrappers unavailable")
      }
      check(firstTrack !== secondTrack && firstTrack.isEqual(secondTrack))
      print("APPLE_RECEIVED_SDK_CASE_OK:fresh-native-wrappers")

      var selected: RTCPeerConnection? = peer
      var current = true
      let directory = AppleReceivedAudioSources.directory(current: { current },
        peer: { $0 == "test-peer" ? selected : nil })
      guard let source = directory.borrow(peerID: "test-peer", receiverID: transceiver.receiver.receiverId,
                                          trackID: audio.trackId),
            let original = source.track as? AppleReceivedAudioTrack else {
        preconditionFailure("Pinned SDK source not admitted")
      }
      let identity = ObjectIdentifier(original.audio)
      for _ in 0..<20 {
        check(source.isCurrent)
        check(ObjectIdentifier((source.track as! AppleReceivedAudioTrack).audio) == identity)
      }
      check(original.audio.isEqual(audio))
      print("APPLE_RECEIVED_SDK_CASE_OK:original-track-retained")
      selected = other
      check(!source.isCurrent)
      selected = peer
      check(!source.isCurrent)
      print("APPLE_RECEIVED_SDK_CASE_OK:peer-scope")
      guard let next = directory.borrow(peerID: "test-peer", receiverID: transceiver.receiver.receiverId,
                                       trackID: audio.trackId) else { preconditionFailure("Fresh source unavailable") }
      current = false; check(!next.isCurrent)
      current = true; check(!next.isCurrent)
      directory.retire()
      check(directory.borrow(peerID: "test-peer", receiverID: transceiver.receiver.receiverId,
                             trackID: audio.trackId) == nil)
      print("APPLE_RECEIVED_SDK_CASE_OK:retirement")
    }
    print("APPLE_RECEIVED_SDK_OK:\(checks)")
  }
}
