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
    // На iOS нет прямого аналога FLAG_SECURE, но можно защитить приложение от скриншотов
    // и размыть контент в multitasking через UIScreenCaptureController
    
    // [FIX] Защита от скриншотов: обнаружение через уведомления
    NotificationCenter.default.addObserver(
      forName: UIApplication.userDidTakeScreenshotNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      print("⚠️ Screenshot detected! User took a screenshot.")
      // Показываем размытие при обнаружении скриншота
      self?.showBlurForCapture()
    }
    
    // [FIX] Обнаружение записи экрана (screen capture)
    NotificationCenter.default.addObserver(
      forName: UIScreen.capturedDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      if UIScreen.main.isCaptured {
        print("⚠️ Screen capture/recording detected!")
        self?.showBlurForCapture()
      } else {
        self?.hideBlurForCapture()
      }
    }
    
    // Размытие в multitasking: создаём overlay view который показывается при переходе в background
    self?.addBlurOverlay()
    
    print("Secure mode enabled")
  }
  
  // [FIX] Мгновенное размытие при обнаружении захвата экрана
  private func showBlurForCapture() {
    guard let window = self?.window else { return }
    if let blurView = window.viewWithTag(99999) {
      blurView.alpha = 1.0
    } else {
      // Если размытия нет, создаём
      self?.addBlurOverlay()
      if let blurView = window.viewWithTag(99999) {
        blurView.alpha = 1.0
      }
    }
  }
  
  // Скрытие размытия
  private func hideBlurForCapture() {
    guard let window = self?.window else { return }
    if let blurView = window.viewWithTag(99999) {
      blurView.alpha = 0.0
    }
  }
  
  private func disableSecureMode() {
    // Удаляем blur overlay при отключении secure mode
    self?.removeBlurOverlay()
    print("Secure mode disabled")
  }
  
  private func addBlurOverlay() {
    guard let window = self?.window else { return }
    
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
    guard let window = self?.window else { return }
    
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

// MARK: - Lifecycle extensions for secure mode
extension AppDelegate {
  override func applicationWillResignActive(_ application: UIApplication) {
    // Показываем blur overlay когда приложение уходит в background
    addBlurOverlay()
  }
  
  override func applicationDidEnterBackground(_ application: UIApplication) {
    // Убеждаемся что blur overlay виден в multitasking
    if let window = window, let blurView = window.viewWithTag(99999) {
      blurView.alpha = 1.0
    }
  }
  
  override func applicationWillEnterForeground(_ application: UIApplication) {
    // Скрываем blur overlay когда приложение возвращается на передний план
    if let window = window, let blurView = window.viewWithTag(99999) {
      blurView.alpha = 0.0
    }
  }
  
  override func applicationDidBecomeActive(_ application: UIApplication) {
    // Полностью удаляем blur overlay когда приложение активно
    removeBlurOverlay()
  }
}
