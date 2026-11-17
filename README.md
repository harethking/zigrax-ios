# ZIGRAX for iOS

The same page as the Android app (`www/ZIGRAX.html` + `www/zx/`) in a WKWebView, served from
`zxapp://localhost/` so fetch, Web Workers, WebAssembly (Stockfish), storage and the microphone work.
Native parts: AdMob rewarded ads (`window.ZXAds`, same API as Android), the share sheet (`window.ZXiOS`),
`zigrax://` game links.

The project is generated with XcodeGen (`project.yml`). The GitHub workflow builds it on a macOS
runner, runs it on the simulator with `-zxSelfTest`, and on demand archives a signed build and
uploads it to App Store Connect.
