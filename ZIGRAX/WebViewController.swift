import UIKit
import WebKit

/// Hosts ZIGRAX.html (the same page as the Android app) in a WKWebView, inside the safe area,
/// with a strip under it that holds a banner ad only when the page asks for one.
final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    static let bg = UIColor(red: 0x12 / 255.0, green: 0x14 / 255.0, blue: 0x1A / 255.0, alpha: 1)

    private var web: WKWebView!
    private let adBox = UIView()
    private var adBoxHeight: NSLayoutConstraint!
    private var pageReady = false
    var pendingLink: String?
    private lazy var ads = Ads(host: self)
    private var native: [String: Any] = ["ads": "off", "privacy": false]

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: game links

    /// zigrax://g?m=..&w=..  or  https://…#m=..&w=..  → "m=..&w=.."
    static func gameQuery(_ url: URL) -> String? {
        let q = url.scheme == "zigrax" ? url.query : url.fragment
        guard let s = q, s.contains("m=") || s.contains("tour=") else { return nil }
        return s
    }

    func openGameLink(_ q: String) {
        if pageReady { sendCall("zxOpenLink", q) }
        else { pendingLink = q; if web != nil { load() } }
    }

    // MARK: setup

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Self.bg

        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(AssetSchemeHandler(), forURLScheme: AssetSchemeHandler.scheme)
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.websiteDataStore = .default()
        let uc = WKUserContentController()
        if let p = Bundle.main.url(forResource: "bridge", withExtension: "js"), let js = try? String(contentsOf: p, encoding: .utf8) {
            uc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        uc.add(WeakHandler(self), name: "zx")
        cfg.userContentController = uc

        web = WKWebView(frame: .zero, configuration: cfg)
        web.isOpaque = false
        web.backgroundColor = Self.bg
        web.scrollView.backgroundColor = Self.bg
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false
        web.allowsBackForwardNavigationGestures = false
        web.navigationDelegate = self
        web.uiDelegate = self
        if #available(iOS 16.4, *) { web.isInspectable = true }
        web.customUserAgent = nil

        adBox.backgroundColor = Self.bg
        adBox.clipsToBounds = true
        web.translatesAutoresizingMaskIntoConstraints = false
        adBox.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        view.addSubview(adBox)
        let g = view.safeAreaLayoutGuide
        adBoxHeight = adBox.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: g.topAnchor),
            web.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: adBox.topAnchor),
            adBox.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            adBox.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            adBox.bottomAnchor.constraint(equalTo: g.bottomAnchor),
            adBoxHeight,
        ])
        Push.shared.host = self
        load()
    }

    private func load() {
        var url = AssetSchemeHandler.startURL
        if let q = pendingLink, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.fragment = "zxg=" + (q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q)
            url = c.url ?? url
            pendingLink = nil
        }
        web.load(URLRequest(url: url))
    }

    // MARK: page ↔ app

    private func json(_ v: Any) -> String {
        if let d = try? JSONSerialization.data(withJSONObject: [v], options: [.fragmentsAllowed]), let s = String(data: d, encoding: .utf8) {
            return String(s.dropFirst().dropLast())   // the value without the [ ] around it
        }
        return "null"
    }

    func sendToPage(_ fn: String, _ obj: [String: Any]) { sendCall(fn, obj) }
    func callPage(_ fn: String, _ arg: Any) { sendCall(fn, arg) }
    var isPageReady: Bool { pageReady }

    private func sendCall(_ fn: String, _ arg: Any) {
        let js = "window.\(fn)&&\(fn)(\(json(arg)))"
        DispatchQueue.main.async { self.web?.evaluateJavaScript(js, completionHandler: nil) }
    }

    func setNativeValue(_ key: String, _ value: Any) {
        native[key] = value
        let js = "window.__zxNative&&__zxNative(\(json(key)),\(json(value)))"
        DispatchQueue.main.async { self.web?.evaluateJavaScript(js, completionHandler: nil) }
    }

    func setBanner(_ v: UIView?) {
        adBox.subviews.forEach { $0.removeFromSuperview() }
        guard let v = v else { adBoxHeight.constant = 0; return }
        v.translatesAutoresizingMaskIntoConstraints = false
        adBox.addSubview(v)
        NSLayoutConstraint.activate([v.centerXAnchor.constraint(equalTo: adBox.centerXAnchor), v.topAnchor.constraint(equalTo: adBox.topAnchor)])
        adBoxHeight.constant = v.intrinsicContentSize.height > 0 ? v.intrinsicContentSize.height : 50
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let fn = m["fn"] as? String else { return }
        let slot = m["slot"] as? String ?? ""
        let test = m["test"] as? Bool ?? true
        switch fn {
        case "share":
            let text = m["text"] as? String ?? ""
            let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
            if let pop = sheet.popoverPresentationController {   // iPad
                pop.sourceView = view
                pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 80, width: 1, height: 1)
            }
            present(sheet, animated: true)
        case "shareFile":
            let name = ((m["name"] as? String) ?? "zigrax.pdf").replacingOccurrences(of: "/", with: "_")
            guard let b64 = m["b64"] as? String, let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { break }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            do { try data.write(to: url, options: .atomic) } catch { break }
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let pop = sheet.popoverPresentationController {   // iPad
                pop.sourceView = view
                pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 80, width: 1, height: 1)
            }
            present(sheet, animated: true)
        case "open":
            if let s = m["url"] as? String, let u = URL(string: s), ["https", "http", "mailto", "itms-apps"].contains(u.scheme ?? "") {
                UIApplication.shared.open(u)
            }
        case "adsStart": ads.start()
        case "banner": ads.showBanner(slot: slot, test: test)
        case "hideBanner": ads.hideBanner()
        case "interstitial": ads.showInterstitial(slot: slot, test: test)
        case "rewarded": ads.showRewarded(slot: slot, test: test)
        case "privacyOptions": ads.privacyOptions()
        case "ntAsk", "ntSetup", "ntTest": Push.shared.handle(m)
        default: break
        }
    }

    // MARK: navigation: our pages stay inside, everything else opens in Safari / the right app

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        let s = url.scheme?.lowercased() ?? ""
        if s == AssetSchemeHandler.scheme || s == "about" || s == "blob" || s == "data" { return decisionHandler(.allow) }
        if action.targetFrame?.isMainFrame == false && (s == "https" || s == "http") { return decisionHandler(.allow) }   // iframes
        if s == "zigrax", let q = Self.gameQuery(url) { openGameLink(q); return decisionHandler(.cancel) }
        UIApplication.shared.open(url)
        decisionHandler(.cancel)
    }

    // target="_blank" links
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if url.scheme == AssetSchemeHandler.scheme { webView.load(URLRequest(url: url)) } else { UIApplication.shared.open(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = webView.url?.scheme == AssetSchemeHandler.scheme
        for (k, v) in native { setNativeValue(k, v) }
        if pageReady { Push.shared.pageReady() }
        if ProcessInfo.processInfo.arguments.contains("-zxSelfTest") { SelfTest.run(webView) }
    }

    // the web content process can be killed by iOS in the background: reload instead of a blank screen
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { load() }

    // microphone for voice messages: only for our own page; iOS still asks the user once
    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.protocol == AssetSchemeHandler.scheme && type == .microphone ? .grant : .deny)
    }

    // alert() / confirm() / prompt() from the page
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "حسناً", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "إلغاء", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "موافق", style: .default) { _ in completionHandler(true) })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "إلغاء", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "موافق", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        present(a, animated: true)
    }
}

/// WKUserContentController keeps its handlers strongly; this avoids a retain cycle.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
}
