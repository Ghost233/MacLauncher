import Cocoa
import FlutterMacOS
import ServiceManagement

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "maclauncher/native",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
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
        switch SMAppService.mainApp.status {
        case .enabled: result("enabled")
        case .requiresApproval: result("requiresApproval")
        case .notFound: result("notFound")
        default: result("notRegistered")
        }
      case "setLoginItemEnabled":
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
