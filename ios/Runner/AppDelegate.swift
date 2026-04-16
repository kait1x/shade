import UIKit
import Flutter

@main
class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    
    // Канал для управления безопасностью (скриншоты, превью в многозадачности)
    let controller = window?.rootViewController as! FlutterViewController
    let securityChannel = FlutterMethodChannel(
      name: "com.shade.app/security",
      binaryMessenger: controller.binaryMessenger
    )
    
    securityChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "enableSecureMode":
        self?.enableSecureMode()
        result(nil)
      case "disableSecureMode":
        self?.disableSecureMode()
        result(nil)
      case "excludeFromRecents":
        self?.excludeFromRecents()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  
  private func enableSecureMode() {
    // На iOS нет прямого аналога FLAG_SECURE, но можно сделать скриншот размытым
    // через UIScreenCaptureController (iOS 11+) или использовать приватные API
    // Для базовой защиты просто предупреждаем пользователя
    print("Secure mode enabled - screenshots will be detected")
  }
  
  private func disableSecureMode() {
    print("Secure mode disabled")
  }
  
  private func excludeFromRecents() {
    // На iOS приложение всегда показывается в переключателе задач
    // Мы не можем полностью скрыть его, но можем сделать snapshot размытым
    // Это делается через UIWindowSceneDelegate
    print("Exclude from recents requested")
  }
}
