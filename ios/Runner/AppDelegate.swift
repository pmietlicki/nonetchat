import Flutter
import UIKit
import MapKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var mapsChannel: FlutterMethodChannel?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = registrar(forPlugin: "NoNetChatAppleFastLane") {
      AppleFastLanePlugin.register(with: registrar)
    }
    if let registrar = registrar(forPlugin: "NoNetChatHotspot") {
      AppleHotspotPlugin.register(with: registrar)
    }
    if let registrar = registrar(forPlugin: "NoNetChatMaps") {
      let channel = FlutterMethodChannel(name: "nonetchat/maps", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "openPoint" else {
          result(FlutterMethodNotImplemented)
          return
        }
        guard UIApplication.shared.applicationState == .active,
              let args = call.arguments as? [String: Any],
              let latitude = args["latitudeE7"] as? Int,
              let longitude = args["longitudeE7"] as? Int,
              (-900000000...900000000).contains(latitude),
              (-1800000000...1800000000).contains(longitude) else {
          result(false)
          return
        }
        // Open the native Maps app, never a browser or a remote map endpoint.
        let point = CLLocationCoordinate2D(latitude: Double(latitude) / 1e7, longitude: Double(longitude) / 1e7)
        let item = MKMapItem(placemark: MKPlacemark(coordinate: point))
        result(item.openInMaps(launchOptions: nil))
      }
      mapsChannel = channel
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
