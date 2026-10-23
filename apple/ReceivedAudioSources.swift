import Foundation

/// Read-only views of public SDK objects. Wrapper identity is not source identity.
@MainActor protocol ReceivedAudioTrack: AnyObject {
  var id: String { get }
  var live: Bool { get }
  var enabled: Bool { get }
  func sameSource(as other: any ReceivedAudioTrack) -> Bool
}

@MainActor protocol ReceivedAudioReceiver: AnyObject {
  var id: String { get }
  var track: (any ReceivedAudioTrack)? { get }
  func sameReceiver(as other: any ReceivedAudioReceiver) -> Bool
}

@MainActor protocol ReceivedAudioPeer: AnyObject {
  var live: Bool { get }
  var receivers: [any ReceivedAudioReceiver] { get }
  func samePeer(as other: any ReceivedAudioPeer) -> Bool
}

/// One explicitly injected engine/account scope. No singleton, SDK factory,
/// microphone, recording, renderer or filesystem is created by this directory.
@MainActor final class ReceivedAudioSources {
  private var current: (() -> Bool)?
  private var lookup: ((String) -> (any ReceivedAudioPeer)?)?
  private var admitting = true
  private var borrowing = false

  init(current: @escaping () -> Bool,
       peer: @escaping (String) -> (any ReceivedAudioPeer)?) {
    self.current = current
    lookup = peer
  }

  func retire() {
    admitting = false
    current = nil
    lookup = nil
  }

  func borrow(peerID: String, receiverID: String, trackID: String) -> ReceivedAudioSource? {
    guard !borrowing, [peerID, receiverID, trackID].allSatisfy(Self.validIdentifier) else { return nil }
    borrowing = true
    defer { borrowing = false }
    guard permitted, let peer = lookup?(peerID), permitted, peer.live,
          let (receiver, track) = selected(peer, receiverID: receiverID, trackID: trackID),
          permitted else { return nil }
    let source = ReceivedAudioSource(directory: self, peerID: peerID,
      receiverID: receiverID, trackID: trackID, peer: peer, receiver: receiver, track: track)
    return source.isCurrent ? source : nil
  }

  fileprivate var permitted: Bool {
    guard admitting, let current else { return false }
    // Even a reentrant callback which returns true cannot undo retire().
    let allowed = current()
    return admitting && allowed
  }

  fileprivate func contains(_ source: ReceivedAudioSource) -> Bool {
    guard permitted, let peer = lookup?(source.peerID), permitted, peer.live,
          peer.samePeer(as: source.peer),
          let (receiver, track) = selected(peer, receiverID: source.receiverID,
                                         trackID: source.trackID),
          receiver.sameReceiver(as: source.receiver),
          track.sameSource(as: source.track), permitted,
          let finalPeer = lookup?(source.peerID), finalPeer.samePeer(as: source.peer),
          finalPeer.live, source.track.live, source.track.enabled else { return false }
    return permitted
  }

  private func selected(_ peer: any ReceivedAudioPeer, receiverID: String,
                        trackID: String) -> ((any ReceivedAudioReceiver), (any ReceivedAudioTrack))? {
    let receivers = peer.receivers
    let matching = receivers.filter { $0.id == receiverID }
    guard permitted, matching.count == 1, let receiver = matching.first,
          let track = receiver.track, track.id == trackID, track.live, track.enabled,
          // A duplicated track ID in this peer is ambiguous, even if its other
          // receiver has a different ID. Never pick whichever came first.
          receivers.filter({ $0.track?.id == trackID }).count == 1,
          permitted else { return nil }
    return (receiver, track)
  }

  private static func validIdentifier(_ value: String) -> Bool {
    // Same local SDK-ID bound as Windows monitor_recording_bridge::Identifier;
    // this is not a new packet field or network quota.
    !value.isEmpty && value.utf16.count <= 256 &&
      value.utf16.allSatisfy { $0 >= 0x20 && $0 != 0x7f }
  }
}

/// Original wrappers remain strongly owned until the eventual renderer/writer
/// drains. Checking a fresh wrapper never rebinds this lease to another source.
@MainActor final class ReceivedAudioSource {
  private weak var directory: ReceivedAudioSources?
  fileprivate let peerID: String, receiverID: String, trackID: String
  fileprivate let peer: any ReceivedAudioPeer
  fileprivate let receiver: any ReceivedAudioReceiver
  let track: any ReceivedAudioTrack
  private var retired = false
  private var checking = false

  fileprivate init(directory: ReceivedAudioSources, peerID: String,
                   receiverID: String, trackID: String, peer: any ReceivedAudioPeer,
                   receiver: any ReceivedAudioReceiver, track: any ReceivedAudioTrack) {
    self.directory = directory
    self.peerID = peerID; self.receiverID = receiverID; self.trackID = trackID
    self.peer = peer; self.receiver = receiver; self.track = track
  }

  func retire() { retired = true }

  var isCurrent: Bool {
    guard !retired, !checking, let directory else {
      retired = true
      return false
    }
    checking = true
    defer { checking = false }
    guard directory.contains(self), !retired else {
      retired = true
      return false
    }
    return true
  }
}
