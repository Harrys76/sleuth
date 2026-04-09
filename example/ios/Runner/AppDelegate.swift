import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Minimal handler for the platform channel demo.
    // Must be registered AFTER the implicit engine is initialized — at that
    // point the registrar's binary messenger is wired up to the live engine.
    // Responds to all methods with nil so Dart-side calls succeed and
    // `debugProfilePlatformChannels` emits real VM timeline events.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "sleuth_demo_channel") {
      let channel = FlutterMethodChannel(
        name: "sleuth_demo_channel",
        binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { _, result in result(nil) }
    }
  }
}
