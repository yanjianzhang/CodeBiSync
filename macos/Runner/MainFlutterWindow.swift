import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    // Set a friendlier initial size and sensible minimums for layout.
    // This helps avoid cramped single-column view on first launch.
    let initialContentSize = NSSize(width: 1280, height: 800)
    let minContentSize = NSSize(width: 1024, height: 700)

    self.setContentSize(initialContentSize)
    self.minSize = minContentSize
    self.center()

    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
