import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var statusItem: NSStatusItem?
  weak var mainWindow: NSWindow?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Menu-bar resident: no Dock icon, no forced main window.
    NSApp.setActivationPolicy(.accessory)

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      button.image = NSImage(
        systemSymbolName: "square.grid.2x2",
        accessibilityDescription: "Ghost Launcher")
    }
    let menu = NSMenu()
    menu.addItem(NSMenuItem(
      title: "显示管理窗口", action: #selector(showMainWindow), keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(
      title: "退出 Ghost Launcher", action: #selector(quitApp), keyEquivalent: "q"))
    item.menu = menu
    statusItem = item

    super.applicationDidFinishLaunching(notification)
  }

  @objc private func showMainWindow() {
    let window = mainWindow ?? NSApp.windows.first { $0 is MainFlutterWindow }
    if let window {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  @objc private func quitApp() {
    NSApp.terminate(nil)
  }

  // Closing the management window never quits the launcher and never implies
  // any business recycle.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
