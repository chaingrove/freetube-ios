# FreeTube for iPhone (unofficial)

This is an **unofficial** iOS port of [FreeTube](https://github.com/FreeTubeApp/FreeTube). It is not made, endorsed or supported by the FreeTube project, so please don't report problems with it to them.

It is not in the App Store. You build it on a Mac and install it on your own iPhone with Xcode and a free Apple ID.

It uses FreeTube's direct connection to YouTube (the "Local API"), not Invidious. Search, channels, subscriptions, playlists, history, captions and video playback work.

## Known limitations

- **Live streams don't play.** YouTube now delivers live streams to FreeTube's web client only through SABR, and FreeTube itself can't play live SABR streams yet. Desktop FreeTube has the same problem.
- **Storage.** Your data (subscriptions, history, playlists, settings) lives in the app's web view storage. iOS does not mark it as persistent, so it could be evicted if the phone runs very low on space. Exporting data to a file does not work yet, and importing from desktop FreeTube is untested.
- **Port 17173.** The app runs a small server on `127.0.0.1:17173` inside the phone. If another app is using that port, FreeTube can't load. The port is also part of where the data is stored, so don't change it.
- **Not implemented:** background audio, lock-screen controls, the Invidious backend and proxy settings.
- **Simulator:** the app runs in the iOS Simulator, but videos don't play there. Use a real iPhone.

## Requirements

| What | Version |
|---|---|
| Mac | macOS 15.6 or newer |
| Xcode | 26 or newer (tested with 26.6) |
| Node.js | 24 or newer (tested with 25.6) |
| pnpm | tested with 12.4 (`npm install -g pnpm`) |
| iPhone | iOS 17.1 or newer (tested on an iPhone 16 Pro with iOS 27.0) |
| Apple ID | a free one is enough |

## 1. Build the web part

```sh
git clone <this repository>
cd <the repository folder>
pnpm install --frozen-lockfile
pnpm run pack:ios
```

`pack:ios` builds FreeTube's interface into `ios/App/App/public`. Run it again after every update.

## 2. Set up signing

1. Open Xcode, then **Xcode > Settings > Accounts**, click **+** and add your Apple ID. A team called "*Your Name* (Personal Team)" appears.
2. Find its 10-character team ID:

   ```sh
   defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier | grep -E 'teamID|teamName'
   ```

3. Create `ios/Signing.local.xcconfig` (git ignores it) with your team ID and a bundle id of your own. Bundle ids are shared across all Apple developers, so pick something unique, such as one with your name in it:

   ```
   DEVELOPMENT_TEAM = ABCDE12345
   PRODUCT_BUNDLE_IDENTIFIER = com.yourname.freetube
   ```

Don't pick the team in Xcode's Signing & Capabilities tab: that writes it into the project file. If the build says `Signing for "App" requires a development team`, the local file is missing or misspelled.

Keep the same bundle id from then on. The app's data belongs to that bundle id, so changing it gives you an empty new app.

## 3. Prepare the iPhone

1. Connect the iPhone to the Mac with a cable, unlock it and tap **Trust** when asked.
2. Turn on **Settings > Privacy & Security > Developer Mode**, let the phone restart, then confirm **Turn On**. The switch only appears after the phone has been connected to Xcode once; if it's missing, open **Window > Devices and Simulators** in Xcode and wait a moment.

## 4. Install

In Xcode: open `ios/App/App.xcodeproj`, wait for the packages to finish downloading, choose your iPhone at the top, and press **Run** (⌘R).

The first launch is blocked as an "Untrusted Developer". On the phone, open **Settings > General > VPN & Device Management**, tap your Apple ID under Developer App, then **Trust**. Launch FreeTube again.

From the terminal instead:

```sh
xcrun devicectl list devices    # note your iPhone's identifier
cd ios/App
xcodebuild -project App.xcodeproj -scheme App -configuration Debug \
  -destination 'id=<identifier>' -allowProvisioningUpdates \
  -packageAuthorizationProvider netrc -derivedDataPath build build
xcrun devicectl device install app --device <identifier> build/Build/Products/Debug-iphoneos/App.app
```

`-packageAuthorizationProvider netrc` stops Swift Package Manager from hanging on a keychain prompt while it downloads the dependencies.

## 5. Every 7 days: re-sign

With a free Apple ID, the app stops opening 7 days after it was signed. Connect the phone and press **Run** in Xcode again (or rerun the terminal commands). Your data stays, as long as the bundle id is unchanged.

Free Apple IDs have two more limits: at most **3** of your own apps on a phone at a time, and at most **10** new bundle ids per 7 days. The paid Apple Developer Program removes these and signs for a year.

## Updating

```sh
git pull
pnpm install --frozen-lockfile
pnpm run pack:ios
```

Then press Run in Xcode.

## How it works

FreeTube's interface runs unchanged in a web view inside a [Capacitor](https://capacitorjs.com/) 8 shell. A web page can't talk to YouTube directly, so a small Swift server inside the app (`ios/LoopbackServer`, built on [FlyingFox](https://github.com/swhitty/FlyingFox)) serves the interface on `127.0.0.1:17173`. It forwards YouTube requests with the same headers and cookie handling as FreeTube's desktop app (`src/main/index.js`), and streams media through to [shaka-player](https://github.com/shaka-project/shaka-player).

- `src/renderer/iosPreloadScript.js` sends the page's YouTube requests through that server.
- `ios/App/App/PoTokenGenerator.swift` creates YouTube's proof-of-origin tokens in a hidden web view, like `src/main/poTokenGenerator.js` does on desktop.
- The rest of the iOS-only code is behind `process.env.IS_IOS`, and the web build lives in `_scripts/webpack.ios.config.js`.

The proxy has tests that run on a Mac: `cd ios/LoopbackServer && swift test`.

## License and credits

Licensed under the [GNU AGPL v3.0](../LICENSE), like FreeTube. This fork modifies FreeTube to add an iOS build (October 2026).

FreeTube is made by the [FreeTube contributors](https://github.com/FreeTubeApp/FreeTube/graphs/contributors). This port only adds the iOS wrapper. [FreeTubeAndroid](https://github.com/MarmadileManteater/FreeTubeAndroid) showed how to run FreeTube's direct YouTube client outside Electron. It also builds on Capacitor, FlyingFox, shaka-player, [YouTube.js](https://github.com/LuanRT/YouTube.js) and [BgUtils](https://github.com/LuanRT/BgUtils).
