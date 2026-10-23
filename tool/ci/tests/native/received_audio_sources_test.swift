import Foundation

@MainActor private final class NativeTrack {
  let id: String
  var live = true, enabled = true
  init(_ id: String = "audio") { self.id = id }
}
@MainActor private final class Track: ReceivedAudioTrack {
  let native: NativeTrack
  var sinks: [String] = [] // Like RTCAudioTrack._adapters, wrapper-local.
  init(_ native: NativeTrack) { self.native = native }
  var id: String { native.id }
  var live: Bool { native.live }
  var enabled: Bool { native.enabled }
  func sameSource(as other: any ReceivedAudioTrack) -> Bool {
    (other as? Track)?.native === native
  }
}
@MainActor private final class NativeReceiver {
  let id: String
  var track: NativeTrack?
  init(_ id: String = "receiver", track: NativeTrack? = NativeTrack()) {
    self.id = id; self.track = track
  }
}
@MainActor private final class Receiver: ReceivedAudioReceiver {
  let native: NativeReceiver
  init(_ native: NativeReceiver) { self.native = native }
  var id: String { native.id }
  var track: (any ReceivedAudioTrack)? { native.track.map(Track.init) }
  func sameReceiver(as other: any ReceivedAudioReceiver) -> Bool {
    (other as? Receiver)?.native === native
  }
}
@MainActor private final class NativePeer {
  var live = true
  var receivers: [NativeReceiver] = [NativeReceiver()]
}
@MainActor private final class Peer: ReceivedAudioPeer {
  let native: NativePeer
  init(_ native: NativePeer) { self.native = native }
  var live: Bool { native.live }
  var receivers: [any ReceivedAudioReceiver] { native.receivers.map(Receiver.init) }
  func samePeer(as other: any ReceivedAudioPeer) -> Bool {
    (other as? Peer)?.native === native
  }
}

@main @MainActor struct ReceivedAudioSourcesTest {
  static var checks = 0
  static func check(_ value: @autoclosure () -> Bool) {
    checks += 1
    precondition(value(), "Received audio source check failed")
  }
  static func mark(_ value: String) { print("RECEIVED_AUDIO_CASE_OK:" + value) }
  static func borrow(_ directory: ReceivedAudioSources) -> ReceivedAudioSource? {
    directory.borrow(peerID: "peer", receiverID: "receiver", trackID: "audio")
  }
  static func main() {
    do {
      let native = NativePeer()
      let directory = ReceivedAudioSources(current: { true }, peer: { $0 == "peer" ? Peer(native) : nil })
      let source = borrow(directory)!
      let original = source.track as! Track
      original.sinks.append("owned-renderer")
      for _ in 0..<50 { check(source.isCurrent); check(source.track === original) }
      let fresh = Receiver(native.receivers[0]).track as! Track
      check(fresh !== original && fresh.sameSource(as: original))
      check(fresh.sinks.isEmpty && original.sinks == ["owned-renderer"])
      source.retire()
      check(!source.isCurrent)
      original.sinks.removeAll() // Removal uses original wrapper even after retirement.
      check(original.sinks.isEmpty)
      mark("fresh-wrappers")
    }
    do {
      var native: NativePeer? = NativePeer()
      let directory = ReceivedAudioSources(current: { true }, peer: { _ in native.map(Peer.init) })
      let source = borrow(directory)!
      native = NativePeer() // Same textual peer, receiver and track IDs.
      check(!source.isCurrent)
      native = nil
      check(!source.isCurrent)
      check(borrow(directory) == nil)
      mark("peer-replacement")
    }
    do {
      let native = NativePeer()
      let directory = ReceivedAudioSources(current: { true }, peer: { _ in Peer(native) })
      let source = borrow(directory)!
      let old = native.receivers[0]
      native.receivers = [NativeReceiver()]
      check(!source.isCurrent)
      native.receivers = [old]
      check(!source.isCurrent)
      check(borrow(directory)?.isCurrent == true)
      mark("receiver-replacement")
    }
    do {
      let native = NativePeer()
      let directory = ReceivedAudioSources(current: { true }, peer: { _ in Peer(native) })
      let source = borrow(directory)!
      let old = native.receivers[0].track!
      native.receivers[0].track = NativeTrack() // Same ID, different native source.
      check(!source.isCurrent)
      native.receivers[0].track = old
      check(!source.isCurrent)
      mark("track-replacement")
    }
    do {
      let native = NativePeer()
      let directory = ReceivedAudioSources(current: { true }, peer: { _ in Peer(native) })
      native.receivers.append(NativeReceiver())
      check(borrow(directory) == nil) // Duplicate receiver IDs.
      native.receivers[1] = NativeReceiver("other", track: NativeTrack())
      check(borrow(directory) == nil) // Duplicate audio track IDs.
      native.receivers[1] = NativeReceiver("other", track: NativeTrack("different"))
      check(borrow(directory)?.isCurrent == true)
      native.receivers[0].track = nil
      check(borrow(directory) == nil) // Also represents a non-audio receiver.
      mark("ambiguous-or-non-audio")
    }
    do {
      for failure in 0..<3 {
        let native = NativePeer()
        let directory = ReceivedAudioSources(current: { true }, peer: { _ in Peer(native) })
        let source = borrow(directory)!
        switch failure {
        case 0: native.live = false
        case 1: native.receivers[0].track!.live = false
        default: native.receivers[0].track!.enabled = false
        }
        check(!source.isCurrent)
        check(borrow(directory) == nil)
        native.live = true; native.receivers[0].track!.live = true; native.receivers[0].track!.enabled = true
        check(!source.isCurrent)
      }
      mark("terminal-liveness")
    }
    do {
      let native = NativePeer()
      var allowed = true
      var directory: ReceivedAudioSources? = ReceivedAudioSources(current: { allowed }, peer: { _ in Peer(native) })
      let source = borrow(directory!)!
      allowed = false; check(!source.isCurrent)
      allowed = true; check(!source.isCurrent)
      let next = borrow(directory!)!
      directory!.retire()
      check(!next.isCurrent && borrow(directory!) == nil)
      let owned = ReceivedAudioSources(current: { true }, peer: { _ in Peer(native) })
      let borrowed = borrow(owned)!
      owned.retire(); check(!borrowed.isCurrent)
      directory = nil; check(!source.isCurrent)
      mark("scope-retirement")
    }
    do {
      let first = NativePeer(), second = NativePeer()
      let a = ReceivedAudioSources(current: { true }, peer: { $0 == "peer" ? Peer(first) : nil })
      let b = ReceivedAudioSources(current: { true }, peer: { $0 == "peer" ? Peer(second) : nil })
      let left = borrow(a)!, right = borrow(b)!
      check(!left.track.sameSource(as: right.track))
      a.retire(); check(!left.isCurrent && right.isCurrent)
      mark("two-engines")
    }
    do {
      let native = NativePeer()
      var directory: ReceivedAudioSources!
      var reenter = true, nested: ReceivedAudioSource?
      directory = ReceivedAudioSources(current: {
        if reenter { reenter = false; nested = borrow(directory) }
        return true
      }, peer: { _ in Peer(native) })
      let source = borrow(directory)
      check(nested == nil && source?.isCurrent == true)
      directory.retire()
      directory = ReceivedAudioSources(current: { true }, peer: { _ in
        directory.retire()
        return Peer(native)
      })
      check(borrow(directory) == nil)
      mark("reentrant-admission")
    }
    do {
      let native = NativePeer()
      var directory: ReceivedAudioSources!
      var source: ReceivedAudioSource?
      var nested = false
      directory = ReceivedAudioSources(current: { true }, peer: { _ in
        if nested { nested = false; check(source?.isCurrent == false) }
        return Peer(native)
      })
      source = borrow(directory)!
      nested = true
      check(source?.isCurrent == false)
      check(source?.isCurrent == false)
      mark("reentrant-validation")
    }
    do {
      let native = NativePeer()
      var visible: NativePeer? = native
      var directory: ReceivedAudioSources? = ReceivedAudioSources(current: { true }, peer: { _ in visible.map(Peer.init) })
      let source = borrow(directory!)!
      visible = nil; check(!source.isCurrent)
      visible = native; check(!source.isCurrent)
      let next = borrow(directory!)!
      directory = nil
      check(!next.isCurrent && next.track.id == "audio")
      mark("lookup-and-owner-loss")
    }
    do {
      let native = NativePeer()
      var calls = 0
      let directory = ReceivedAudioSources(current: { true }, peer: { _ in calls += 1; return Peer(native) })
      for invalid in ["", "line\n", "tab\t", "nul\0", "del\u{7f}", String(repeating: "a", count: 257)] {
        check(directory.borrow(peerID: invalid, receiverID: "receiver", trackID: "audio") == nil)
        check(directory.borrow(peerID: "peer", receiverID: invalid, trackID: "audio") == nil)
        check(directory.borrow(peerID: "peer", receiverID: "receiver", trackID: invalid) == nil)
      }
      check(calls == 0)
      for boundary in [String(repeating: "a", count: 256), String(repeating: "😀", count: 128)] {
        check(directory.borrow(peerID: boundary, receiverID: "receiver", trackID: "audio")?.isCurrent == true)
      }
      check(directory.borrow(peerID: String(repeating: "😀", count: 129), receiverID: "receiver", trackID: "audio") == nil)
      mark("identifier-boundaries")
    }
    do {
      @MainActor final class Owner { let peer = NativePeer() }
      @MainActor final class WeakOwner {
        weak var value: Owner?
        init(_ value: Owner?) { self.value = value }
      }
      var owner: Owner? = Owner()
      let oldOwner = WeakOwner(owner)
      let directory = ReceivedAudioSources(current: { [held = owner!] in held.peer.live },
        peer: { [held = owner!] _ in Peer(held.peer) })
      let source = borrow(directory)!
      owner = nil
      check(oldOwner.value != nil)
      directory.retire()
      check(oldOwner.value == nil) // Drop engine callbacks, not the cleanup's original track.
      check(!source.isCurrent && source.track.id == "audio")
      mark("retired-callbacks")
    }
    print("RECEIVED_AUDIO_OK:\(checks)")
  }
}
