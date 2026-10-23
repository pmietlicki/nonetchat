import Foundation

/// A weak registration witness, not a process-wide plugin directory. The real
/// registrar must be the only owner of lifetime after registration finishes.
@MainActor final class RegisteredPluginSource<Plugin: AnyObject> {
  private weak var scope: AnyObject?
  private weak var lifetime: AnyObject?
  private weak var plugin: Plugin?
  private var admitting = true
  private var observed = false

  init(scope: AnyObject, lifetime: AnyObject) {
    self.scope = scope
    self.lifetime = lifetime
  }

  func observe(_ value: Plugin) {
    guard admitting, scope != nil, lifetime != nil else { retire(); return }
    if observed {
      // A new instance must never take over existing leases, even when the
      // previous instance has already gone away. Same-instance callbacks are OK.
      guard plugin === value else { retire(); return }
    } else {
      observed = true
      plugin = value
    }
  }

  var current: Plugin? {
    guard admitting, scope != nil, lifetime != nil else { retire(); return nil }
    guard let plugin else {
      if observed { retire() }
      return nil
    }
    return plugin
  }

  func retire() {
    admitting = false
    scope = nil
    lifetime = nil
    plugin = nil
  }
}
