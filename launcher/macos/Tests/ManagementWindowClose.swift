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
application.finishLaunching()
guard application.activationPolicy() == .accessory else {
  fputs("FAIL: launcher starts with a Dock entry before opening the management window\n", stderr)
  exit(1)
}

for cycle in 1...2 {
  // Use the same target/action as the menu-bar entry, rather than bypassing it.
  guard application.sendAction(NSSelectorFromString("showMainWindow"), to: delegate, from: nil) else {
    fputs("FAIL: menu-bar action could not open the management window\n", stderr)
    exit(1)
  }
  guard window.isVisible else {
    fputs("FAIL: management window could not be reopened\n", stderr)
    exit(1)
  }
  guard application.activationPolicy() == .regular else {
    fputs("FAIL: opening management window does not show the application in Dock\n", stderr)
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
  print("PASS: cycle \(cycle) shows Dock on open, hides Dock on close and keeps launcher running")
}
