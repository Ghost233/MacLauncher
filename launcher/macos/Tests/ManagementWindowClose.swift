import Cocoa
import FlutterMacOS

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
let window = MainFlutterWindow(
  contentRect: NSRect(x: -10000, y: -10000, width: 320, height: 240),
  styleMask: [.titled, .closable],
  backing: .buffered,
  defer: false)
window.isReleasedWhenClosed = false
delegate.mainWindow = window

for cycle in 1...2 {
  // Reproduce the running application's observed policy before closing.
  application.setActivationPolicy(.regular)
  window.makeKeyAndOrderFront(nil)
  guard window.isVisible else {
    fputs("FAIL: management window could not be reopened\n", stderr)
    exit(1)
  }
  window.performClose(nil)
  guard !window.isVisible else {
    fputs("FAIL: close did not hide the management window\n", stderr)
    exit(1)
  }
  guard application.activationPolicy() == .accessory else {
    fputs("FAIL: closing management window leaves the application in Dock mode\n", stderr)
    exit(1)
  }
  guard !delegate.applicationShouldTerminateAfterLastWindowClosed(application) else {
    fputs("FAIL: closing management window would quit the launcher\n", stderr)
    exit(1)
  }
  print("PASS: close/reopen cycle \(cycle) hides Dock presence and keeps launcher running")
}
