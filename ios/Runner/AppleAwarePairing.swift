// Adapted from Apple BuildingPeerToPeerApps, DeviceDiscoveryPairingView.
// Copyright © 2025 Apple Inc. License: ../../apple/APPLE-SAMPLE-LICENSE.txt
#if canImport(WiFiAware) && canImport(DeviceDiscoveryUI)
import UIKit
import SwiftUI
import WiFiAware
import DeviceDiscoveryUI
import Network

/// Apple's BuildingPeerToPeerApps DeviceDiscoveryPairingView pattern. The
/// system owns PIN entry; app identity verification remains a separate proof.
@available(iOS 26.0, *)
@MainActor
final class AppleAwarePairing: NSObject, ApplePairingLease, UIAdaptivePresentationControllerDelegate {
  private weak var controller: UIViewController?
  private var onCancel: (() -> Void)?
  private var onSelect: ((UInt64) -> Void)?
  private var observation: Task<Void, Never>?
  private var closed = false

  static func present(listening: Bool, label: String, cancelLabel: String, rtl: Bool, onSelect: @escaping (UInt64) -> Void, onCancel: @escaping () -> Void) -> AppleAwarePairing? {
    guard UIApplication.shared.applicationState == .active,
          let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
          let presenter = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController,
          presenter.presentedViewController == nil,
          WAPublishableService.allServices[AppleAwarePairingView.service] != nil,
          WASubscribableService.allServices[AppleAwarePairingView.service] != nil else { return nil }
    let lease = AppleAwarePairing()
    lease.onCancel = onCancel; lease.onSelect = onSelect
    lease.observation = Task { @MainActor [weak lease, weak presenter] in
      guard let lease = lease, let presenter = presenter else { return }
      do {
        let iterator = WAPairedDevice.allDevices.makeAsyncIterator()
        let before = try await iterator.next() ?? [:]
        guard !lease.closed, !Task.isCancelled, presenter.presentedViewController == nil,
              UIApplication.shared.applicationState == .active else { lease.cancel(); return }
        let view = AppleAwarePairingView(listening: listening, label: label, cancelLabel: cancelLabel,
            existing: Array(before.values).sorted { $0.id < $1.id },
            selected: { [weak lease] device in lease?.select(device) },
            cancelled: { [weak lease] in lease?.cancel() })
          .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
        let controller = UIHostingController(rootView: view)
        lease.controller = controller
        presenter.present(controller, animated: !UIAccessibility.isReduceMotionEnabled)
        controller.presentationController?.delegate = lease
        if listening {
          while let devices = try await iterator.next() {
            guard !lease.closed, !Task.isCancelled else { return }
            let added = devices.keys.filter { before[$0] == nil }
            // Never guess amongst concurrent pairings or expose old pairs.
            if added.count == 1 { lease.select(added[0]); return }
            if added.count > 1 { lease.cancel(); return }
          }
        }
      } catch { lease.cancel() }
    }
    return lease
  }

  private func select(_ device: UInt64) {
    guard !closed else { return }
    let callback = onSelect; onSelect = nil; onCancel = nil
    close(); callback?(device)
  }
  private func cancel() {
    let callback = onCancel; onCancel = nil; onSelect = nil
    close(); callback?()
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    controller = nil; cancel()
  }
  func close() {
    onCancel = nil
    onSelect = nil; closed = true
    observation?.cancel(); observation = nil
    // Dismiss only our hosting route, never a different screen above it.
    if let controller = controller {
      controller.dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }
    controller = nil
  }
}

@available(iOS 26.0, *)
private struct AppleAwarePairingView: View {
  static let service = "_nonet-fast._tcp"
  let listening: Bool
  let label: String
  let cancelLabel: String
  let existing: [WAPairedDevice]
  let selected: (UInt64) -> Void
  let cancelled: () -> Void
  var body: some View {
    VStack(spacing: 16) {
      Text(label).font(.headline).accessibilityAddTraits(.isHeader).padding()
      ScrollView {
        LazyVStack(spacing: 12) {
          if listening && !existing.isEmpty {
            ForEach(existing, id: \.id) { device in
              if let name = device.name, !name.isEmpty {
                Button { selected(device.id) } label: {
                  Label(name, systemImage: "iphone.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                }
              }
            }
          }
          Group {
            if listening, let service = WAPublishableService.allServices[Self.service] {
              DevicePairingView(.wifiAware(.connecting(to: service, from: .userSpecifiedDevices))) {
                Text(label).padding()
              } fallback: {
                Text(label).disabled(true).padding()
              }
            } else if let service = WASubscribableService.allServices[Self.service] {
              DevicePicker(.wifiAware(.connecting(to: .userSpecifiedDevices, from: service))) { endpoint in
                // System pairing never replaces the TLS secret or app pin.
                selected(endpoint.device.id)
              } label: {
                Text(label).padding()
              } fallback: {
                Text(label).disabled(true).padding()
              }
            }
          }.padding()
        }.padding()
      }
      Button(cancelLabel, role: .cancel, action: cancelled)
        .frame(minHeight: 48).padding(.horizontal).padding(.bottom)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
#endif
