import Flutter
import UIKit
import VideoToolbox

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
    let channel = FlutterMethodChannel(
      name: "com.blue.segmeris/media_store",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "getRuntimeCapabilities" else {
        result(FlutterMethodNotImplemented)
        return
      }
      DispatchQueue.global(qos: .utility).async {
        let available = segmeris_videotoolbox_available() != 0
        let hardware: Any
        if #available(iOS 17.4, *) {
          hardware = available
        } else {
          hardware = NSNull()
        }
        var decoders: [String] = []
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) {
          decoders.append("Apple VideoToolbox | video/avc")
        }
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
          decoders.append("Apple VideoToolbox | video/hevc")
        }
        let report: [String: Any] = [
          "transcoderBackend": "Apple AVFoundation / VideoToolbox",
          "hardwareAccelerated": hardware,
          "videoEncoders": available ? ["Apple VideoToolbox | video/avc"] : [],
          "videoDecoders": decoders,
          "ffmpegAvailable": false,
          "ytdlpAvailable": false,
        ]
        DispatchQueue.main.async { result(report) }
      }
    }
  }
}
