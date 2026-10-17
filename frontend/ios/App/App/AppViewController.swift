import Capacitor
import UIKit

// The storyboard's view controller (Main.storyboard). Capacitor 7 only registers the plugins npm
// packages list in capacitor.config.json; the app's own plugins are registered here.
class AppViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(RestAlertPlugin())
        bridge?.registerPluginInstance(PrintPlugin())
        bridge?.registerPluginInstance(WatchPlugin())
        #if DEBUG
        runDebugScript()
        #endif
    }

    #if DEBUG
    // Simulator testing without taps: a Debug build launched with OG_EVAL=<path to a .js file>
    //   SIMCTL_CHILD_OG_EVAL=/path/to/steps.js xcrun simctl launch <udid> <bundle id>
    // runs that file in the page once it has loaded. console.log lands in the device log.
    private func runDebugScript() {
        guard let path = ProcessInfo.processInfo.environment["OG_EVAL"],
              let js = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.webView?.evaluateJavaScript(js) { _, error in
                if let error { CAPLog.print("⚡️  OG_EVAL failed: \(error)") }
            }
        }
    }
    #endif
}
