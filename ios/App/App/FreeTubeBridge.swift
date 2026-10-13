import Foundation
import Capacitor
import LoopbackServer

/// The native half of the iOS build, doing what the desktop app's main process does:
/// the loopback YouTube proxy (header rules from src/main/index.js, in ios/LoopbackServer)
/// and PoToken generation (src/main/poTokenGenerator.js, see PoTokenGenerator.swift).
@objc(FreeTubeBridge)
public class FreeTubeBridge: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "FreeTubeBridge"
    public let jsName = "FreeTubeBridge"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "generatePoToken", returnType: CAPPluginReturnPromise)
    ]

    static let port = LoopbackConfiguration.defaultPort
    private(set) static var token = ""
    private static var server: LoopbackServer?

    /// Starts the loopback server and returns once it is listening, so call it before the WebView loads.
    static func startLoopbackServer() {
        guard let webDirectory = Bundle.main.url(forResource: "public", withExtension: nil) else {
            fatalError("public/ missing from the app bundle, run `pnpm run pack:ios` first")
        }
        let configuration = LoopbackConfiguration(
            port: port,
            webDirectory: webDirectory,
            log: { line in NSLog("[loopback] %@", line) }
        )
        token = configuration.token
        server = LoopbackLauncher.startAndWait(configuration: configuration)
    }

    @MainActor private lazy var poTokenGenerator = PoTokenGenerator()

    @objc func generatePoToken(_ call: CAPPluginCall) {
        guard let videoId = call.getString("videoId"),
              let context = call.getString("context"),
              let initialAttestationData = call.getString("initialAttestationData"),
              let ytConfig = call.getString("ytConfig") else {
            call.reject("videoId, context, initialAttestationData and ytConfig are required")
            return
        }

        Task { @MainActor in
            guard let hostView = self.bridge?.viewController?.view.window else {
                call.reject("no view to host the PoToken web view")
                return
            }
            do {
                let poToken = try await self.poTokenGenerator.generate(
                    videoId: videoId,
                    context: context,
                    initialAttestationData: initialAttestationData,
                    ytConfig: ytConfig,
                    hostView: hostView
                )
                call.resolve(["poToken": poToken])
            } catch {
                call.reject("PoToken generation failed: \(error.localizedDescription)")
            }
        }
    }
}
