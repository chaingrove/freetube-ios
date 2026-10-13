import UIKit
import Capacitor

class BridgeViewController: CAPBridgeViewController {
    /// `server.url` in capacitor.config.json is fixed at build time, but the loopback token changes on
    /// every launch. The page reads it from `location.search`, and the server also sets it as a cookie.
    override func instanceDescriptor() -> InstanceDescriptor {
        let descriptor = super.instanceDescriptor()
        descriptor.serverURL = "http://127.0.0.1:\(FreeTubeBridge.port)/?ft=\(FreeTubeBridge.token)"
        return descriptor
    }

    /// Keeps the web view inside the safe area, so FreeTube's fixed top and bottom bars clear the
    /// Dynamic Island and the home indicator without CSS changes. The web view goes into a plain
    /// container rather than a child view controller: WebKit moves it into its own window for
    /// element full screen, and UIKit aborts if it is a child view controller's root view.
    override func viewDidLoad() {
        super.viewDidLoad()
        guard let webView else { return }
        let container = UIView(frame: webView.frame)
        container.backgroundColor = .systemBackground
        view = container
        container.addSubview(webView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // While WebKit shows the web view full screen, it is not in this view
        if let webView, webView.superview == view {
            webView.frame = view.bounds.inset(by: view.safeAreaInsets)
        }
    }

    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(FreeTubeBridge())
    }
}
