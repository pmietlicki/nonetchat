import Foundation

@main @MainActor struct RegisteredPluginSourceTest {
  final class Value {}
  static var checks = 0
  static func check(_ value: @autoclosure () -> Bool) {
    checks += 1
    precondition(value(), "Registration scope check failed")
  }
  static func main() {
    let scope = Value(), lifetime = Value(), first = Value(), second = Value()
    let source = RegisteredPluginSource<Value>(scope: scope, lifetime: lifetime)
    check(source.current == nil) // Waiting for registration is not terminal.
    source.observe(first); check(source.current === first)
    source.observe(first); check(source.current === first)
    print("REGISTERED_PLUGIN_CASE_OK:one-instance")
    source.observe(second); check(source.current == nil)
    source.observe(first); check(source.current == nil)
    print("REGISTERED_PLUGIN_CASE_OK:ambiguous-registration")

    var witness: Value? = Value()
    let lost = RegisteredPluginSource<Value>(scope: scope, lifetime: witness!)
    lost.observe(first); check(lost.current === first)
    witness = nil; check(lost.current == nil)
    lost.observe(first); check(lost.current == nil)
    print("REGISTERED_PLUGIN_CASE_OK:publication-loss")

    var registry: Value? = Value()
    let root = RegisteredPluginSource<Value>(scope: registry!, lifetime: lifetime)
    root.observe(first); check(root.current === first)
    registry = nil; check(root.current == nil)
    print("REGISTERED_PLUGIN_CASE_OK:registry-loss")

    var sdk: Value? = Value()
    let weakSDK = RegisteredPluginSource<Value>(scope: scope, lifetime: lifetime)
    weakSDK.observe(sdk!); check(weakSDK.current === sdk)
    sdk = nil; check(weakSDK.current == nil)
    weakSDK.observe(second); check(weakSDK.current == nil)
    print("REGISTERED_PLUGIN_CASE_OK:sdk-loss")

    let a = RegisteredPluginSource<Value>(scope: scope, lifetime: lifetime)
    let b = RegisteredPluginSource<Value>(scope: scope, lifetime: lifetime)
    a.observe(first); b.observe(second)
    check(a.current === first && b.current === second)
    a.retire(); check(a.current == nil && b.current === second)
    a.observe(first); check(a.current == nil)
    b.retire(); b.retire(); check(b.current == nil)
    print("REGISTERED_PLUGIN_CASE_OK:independent-retirement")

    let before = RegisteredPluginSource<Value>(scope: scope, lifetime: lifetime)
    before.retire(); before.observe(first); check(before.current == nil)
    print("REGISTERED_PLUGIN_CASE_OK:retire-before-registration")
    print("REGISTERED_PLUGIN_OK:\(checks)")
  }
}
