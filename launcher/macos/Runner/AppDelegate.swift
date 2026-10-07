import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var statusItem: NSStatusItem?
  private var pendingDiscoveryItem: NSMenuItem?
  private var pendingDiscoverySeparator: NSMenuItem?
  weak var mainWindow: NSWindow?
  var nativeChannel: FlutterMethodChannel?
  private var waitingForEntryRelease = false
  private var readyToTerminate = false

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

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if readyToTerminate { return .terminateNow }
    if waitingForEntryRelease { return .terminateLater }
    guard let nativeChannel else { return .terminateNow }
    waitingForEntryRelease = true
    let finish = { [weak self] in
      guard let self, !self.readyToTerminate else { return }
      self.readyToTerminate = true
      sender.reply(toApplicationShouldTerminate: true)
    }
    // Give Dart a bounded opportunity to return entries and close SDK sessions.
    // The SDK's disconnect fallback also covers crashes or an unresponsive engine.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: finish)
    nativeChannel.invokeMethod("prepareToQuit", arguments: nil) { _ in finish() }
    return .terminateLater
  }

  /// 待批准菜单行（#45 运行时发现，最小实现）：有待批准应用时托盘菜单
  /// 顶部出现一行，点击打开管理窗口；清零时移除。
  func setPendingDiscoveryCount(_ count: Int) {
    guard let menu = statusItem?.menu else { return }
    if count > 0 {
      let title = "有待批准的应用（\(count)）"
      if let item = pendingDiscoveryItem {
        item.title = title
      } else {
        let item = NSMenuItem(
          title: title, action: #selector(showMainWindow), keyEquivalent: "")
        menu.insertItem(item, at: 0)
        let separator = NSMenuItem.separator()
        menu.insertItem(separator, at: 1)
        pendingDiscoveryItem = item
        pendingDiscoverySeparator = separator
      }
    } else {
      if let item = pendingDiscoveryItem { menu.removeItem(item) }
      if let separator = pendingDiscoverySeparator { menu.removeItem(separator) }
      pendingDiscoveryItem = nil
      pendingDiscoverySeparator = nil
    }
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
