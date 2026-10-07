import Cocoa
import FlutterMacOS
import ServiceManagement

class MainFlutterWindow: NSWindow {
  #if DEBUG
  // Debug 专用：报告窗口始终可见，让 Flutter 在窗口被遮挡/应用退到后台时
  // 继续调度帧——自动化验收（VM service 截图/渲染树）依赖实时画面。
  // 仅影响 debug 构建，release 行为不变。
  override var occlusionState: NSWindow.OcclusionState { .visible }
  #endif

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "maclauncher/native",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    (NSApp.delegate as? AppDelegate)?.nativeChannel = channel
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "pickManifest":
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "maclauncher.json"
        panel.message = "选择项目目录中的 maclauncher.json"
        result(panel.runModal() == .OK ? panel.url?.path : nil)
      case "loginItemStatus":
        if #available(macOS 13.0, *) {
          switch SMAppService.mainApp.status {
          case .enabled: result("enabled")
          case .requiresApproval: result("requiresApproval")
          case .notFound: result("notFound")
          default: result("notRegistered")
          }
        } else {
          result("notFound")
        }
      case "setLoginItemEnabled":
        if #available(macOS 13.0, *) {
          let enable = (call.arguments as? Bool) ?? false
          do {
            if enable {
              try SMAppService.mainApp.register()
            } else {
              try SMAppService.mainApp.unregister()
            }
            result(nil)
          } catch {
            result(FlutterError(
              code: "login-item",
              message: error.localizedDescription,
              details: nil))
          }
        } else {
          result(FlutterError(
            code: "login-item",
            message: "登录项需要 macOS 13 或更高版本",
            details: nil))
        }
      case "setPendingDiscoveryCount":
        // 待批准菜单行（#45）：管理窗口之外的唯一发现入口提示。
        (NSApp.delegate as? AppDelegate)?.setPendingDiscoveryCount(
          (call.arguments as? Int) ?? 0)
        result(nil)
      case "appVersion":
        // The build channel for the launcher's own version: `flutter build`
        // injects the pubspec version into these Info.plist keys, so the UI
        // never hardcodes a version string (issue #31).
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        result(short.isEmpty ? nil : (build.isEmpty ? short : "\(short)+\(build)"))
      case "relaunch":
        // Hand the running instance to a fresh process, then terminate this
        // one. The launcher never replaces its own .app (ADR 0002); the user
        // has already swapped the binary from the DMG by this point.
        let bundleURL = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundleURL.path]
        do {
          try task.run()
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
          }
          result(nil)
        } catch {
          result(FlutterError(
            code: "relaunch",
            message: error.localizedDescription,
            details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()

    // The management window is optional: the launcher lives in the menu bar
    // by default and the window opens on demand. Closing it only hides it.
    self.isReleasedWhenClosed = false
    (NSApp.delegate as? AppDelegate)?.mainWindow = self
    self.orderOut(nil)
  }
}
