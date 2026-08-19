import AVFoundation
import Flutter
import MediaPlayer
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var audioOutputChannel: FlutterMethodChannel?
  private var audioOutputController: AudioOutputController?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "app.oneone/audio_output",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    audioOutputChannel = channel
    let controller = AudioOutputController(channel: channel)
    audioOutputController = controller
    controller.start()
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getState":
        result(controller.stateMap())
      case "setMuted":
        controller.setMuted(call.arguments as? Bool ?? false)
        result(controller.stateMap())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

/// Current audio route + output-volume mute, pushed to Flutter when headphones
/// plug in or the user changes volume with the hardware buttons.
final class AudioOutputController: NSObject {
  private let channel: FlutterMethodChannel
  private var volumeObservation: NSKeyValueObservation?
  private var volumeView: MPVolumeView?
  private var lastUnmutedVolume: Float = 0.5
  private var emitting = false

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  func start() {
    let session = AVAudioSession.sharedInstance()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleRouteChange),
      name: AVAudioSession.routeChangeNotification,
      object: session
    )
    volumeObservation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
      self?.emitState()
    }
  }

  func stateMap() -> [String: Any] {
    [
      "route": currentRoute(),
      "muted": AVAudioSession.sharedInstance().outputVolume < 0.01,
    ]
  }

  func setMuted(_ muted: Bool) {
    let session = AVAudioSession.sharedInstance()
    if muted {
      lastUnmutedVolume = max(session.outputVolume, 0.05)
      setSystemVolume(0)
    } else {
      let restored = lastUnmutedVolume > 0.01 ? lastUnmutedVolume : 0.5
      setSystemVolume(restored)
    }
    emitState()
  }

  @objc private func handleRouteChange(_ notification: Notification) {
    emitState()
  }

  private func emitState() {
    if emitting { return }
    emitting = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
      guard let self else { return }
      self.emitting = false
      self.channel.invokeMethod("onStateChanged", arguments: self.stateMap())
    }
  }

  private func currentRoute() -> String {
    let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
    for output in outputs {
      switch output.portType {
      case .builtInSpeaker:
        return "speaker"
      case .builtInReceiver:
        return "earpiece"
      case .headphones, .headsetMic:
        return "headset"
      case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
        return "bluetooth"
      default:
        continue
      }
    }
    return "speaker"
  }

  private func setSystemVolume(_ value: Float) {
    let view = volumeView ?? MPVolumeView(frame: .zero)
    volumeView = view
    view.isHidden = true
    view.alpha = 0.0001
    if view.superview == nil {
      let window = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first { $0.isKeyWindow }
      window?.addSubview(view)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      if let slider = view.subviews.first(where: { $0 is UISlider }) as? UISlider {
        slider.value = value
        slider.sendActions(for: .valueChanged)
      }
    }
  }
}
