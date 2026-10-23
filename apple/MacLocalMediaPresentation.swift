#if os(macOS)
import AppKit

@MainActor final class MacLocalMediaPresentation: NSObject, LocalMediaPresentation {
  private var item: NSStatusItem?
  private var key: LocalMediaOwnership.Key?
  private var stop: (@MainActor () -> Void)?
  private var observation: NSKeyValueObservation?
  private var withdrawing = false

  var foreground: Bool { NSApp.isActive }

  func present(_ view: LocalMediaView, stop: @escaping @MainActor () -> Void) async -> Bool {
    guard item == nil, key == nil, foreground else { return false }
    key = view.key; self.stop = stop
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    self.item = item
    item.behavior = .removalAllowed
    guard let button = item.button,
          let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: view.title) else { return false }
    image.isTemplate = true
    button.image = image
    observation = item.observe(\.isVisible, options: [.new]) { [weak self, weak item] _, change in
      guard change.newValue == false else { return }
      Task { @MainActor in
        guard let self, let item, self.item === item,
              self.key === view.key, !self.withdrawing else { return }
        self.stop?()
      }
    }
    return await update(view)
  }

  func update(_ view: LocalMediaView) async -> Bool {
    guard key === view.key, let item, item.isVisible, let button = item.button else { return false }
    button.toolTip = view.title + " — " + view.body
    button.setAccessibilityLabel(view.title + ", " + view.body)
    let menu = NSMenu()
    for text in [view.title, view.body] {
      let label = NSMenuItem(title: text, action: nil, keyEquivalent: "")
      let paragraph = NSMutableParagraphStyle()
      paragraph.baseWritingDirection = view.rightToLeft ? .rightToLeft : .leftToRight
      label.attributedTitle = NSAttributedString(string: text, attributes: [.paragraphStyle: paragraph])
      label.isEnabled = false
      menu.addItem(label)
    }
    menu.addItem(.separator())
    let action = NSMenuItem(title: view.stop, action: #selector(MediaStopTarget.stopFromMenu(_:)), keyEquivalent: "")
    // The target is immutable for this menu, so a retained old menu cannot
    // obtain a successor by looking up the presentation's current purpose.
    let target = MediaStopTarget(key: view.key) { [weak self] key in
      guard let self, self.key === key else { return }
      self.stop?()
    }
    action.target = target
    action.representedObject = target // NSMenuItem's target is not an owner.
    menu.addItem(action)
    item.menu = menu
    return item.isVisible && item.button != nil
  }

  func exists(_ key: LocalMediaOwnership.Key) async -> Bool {
    // Apple documents true even under menu-bar crowding: this is ownership,
    // never a claim that the user has observed a continuously visible icon.
    self.key === key && item?.isVisible == true && item?.button != nil
  }

  func remove(_ key: LocalMediaOwnership.Key) async -> Bool {
    guard self.key === key else { return false }
    guard let item else { return false }
    withdrawing = true
    item.isVisible = false
    guard !item.isVisible else { withdrawing = false; return false }
    observation = nil
    NSStatusBar.system.removeStatusItem(item)
    self.item = nil; self.key = nil; stop = nil; withdrawing = false
    return true
  }
}

@MainActor private final class MediaStopTarget: NSObject {
  private let key: LocalMediaOwnership.Key
  private let invoke: @MainActor (LocalMediaOwnership.Key) -> Void
  init(key: LocalMediaOwnership.Key, invoke: @escaping @MainActor (LocalMediaOwnership.Key) -> Void) {
    self.key = key; self.invoke = invoke
  }
  @objc func stopFromMenu(_ sender: NSMenuItem) { invoke(key) }
}
#endif
