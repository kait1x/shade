import UIKit
import Flutter

@main
class AppDelegate: FlutterAppDelegate {
  private var secureModeEnabled = false
  private var captureObservers: [NSObjectProtocol] = []
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    
    // Канал для управления безопасностью (скриншоты, превью в многозадачности)
    guard let controller = window?.rootViewController as? FlutterViewController else {
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
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
    guard !secureModeEnabled else { return }
    secureModeEnabled = true
    captureObservers.append(NotificationCenter.default.addObserver(
      forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.updatePrivacyOverlay() })
    updatePrivacyOverlay()
  }

  private func updatePrivacyOverlay() {
    guard secureModeEnabled, let window = window else { return }
    addBlurOverlay()
    window.viewWithTag(99999)?.alpha =
      (UIApplication.shared.applicationState != .active || UIScreen.main.isCaptured) ? 1 : 0
  }

  private func disableSecureMode() {
    secureModeEnabled = false
    captureObservers.forEach { NotificationCenter.default.removeObserver($0) }
    captureObservers.removeAll()
    removeBlurOverlay()
  }

  private func addBlurOverlay() {
    guard let window = window else { return }
    
    guard window.viewWithTag(99999) == nil else { return }
    // Создаём визуальный эффект размытия
    let blurEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
    let blurView = UIVisualEffectView(effect: blurEffect)
    blurView.frame = window.bounds
    blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    blurView.tag = 99999 // Tag для последующего удаления
    blurView.alpha = 0 // Скрыт по умолчанию
    
    window.addSubview(blurView)
  }
  
  private func removeBlurOverlay() {
    guard let window = window else { return }
    
    // Находим и удаляем blur overlay по tag
    if let blurView = window.viewWithTag(99999) {
      blurView.removeFromSuperview()
    }
  }
  
  private func excludeFromRecents() {
    // На iOS приложение всегда показывается в переключателе задач
    // Мы не можем полностью скрыть его, но можем сделать snapshot размытым
    // Это достигается через show/hide blur overlay в AppDelegate lifecycle methods
    print("Exclude from recents - blur overlay will be shown in app switcher")
  }
}

// Screen recordings and app-switcher snapshots are obscured best-effort.
// iOS does not offer a general Android FLAG_SECURE equivalent for screenshots.
extension AppDelegate {
  override func applicationWillResignActive(_ application: UIApplication) {
    super.applicationWillResignActive(application)
    if secureModeEnabled { addBlurOverlay(); window?.viewWithTag(99999)?.alpha = 1 }
  }
  override func applicationDidEnterBackground(_ application: UIApplication) {
    super.applicationDidEnterBackground(application)
    if secureModeEnabled { addBlurOverlay(); window?.viewWithTag(99999)?.alpha = 1 }
  }
  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    updatePrivacyOverlay()
  }
}
