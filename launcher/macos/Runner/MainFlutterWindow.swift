import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    // The management window is optional: the launcher lives in the menu bar
    // by default and the window opens on demand. Closing it only hides it.
    self.isReleasedWhenClosed = false
    (NSApp.delegate as? AppDelegate)?.mainWindow = self
    self.orderOut(nil)
  }
}
