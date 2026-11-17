import UIKit
import GoogleMobileAds
import UserMessagingPlatform
import AppTrackingTransparency

/// AdMob for the page (window.ZXAds). Nothing starts until the page calls ZXAds.start(), which it only
/// does when the server config turns ads on, and an ad appears only where the page asks for one.
/// The ad units for iOS come from Info.plist (ZXAdUnits); test mode always uses Google's test units.
final class Ads: NSObject, FullScreenContentDelegate, BannerViewDelegate {
    private weak var host: WebViewController?
    private(set) var ready = false
    private var starting = false
    private var banner: BannerView?
    private var bannerSlot = ""
    private var showing: [ObjectIdentifier: (slot: String, rewarded: Bool)] = [:]
    private var earned = Set<ObjectIdentifier>()
    private var live: [AnyObject] = []          // keeps full-screen ads alive while on screen

    private static let testBanner = "ca-app-pub-3940256099942544/2435281174"
    private static let testInter = "ca-app-pub-3940256099942544/4411468910"
    private static let testReward = "ca-app-pub-3940256099942544/1712485313"

    init(host: WebViewController) { self.host = host }

    private func unit(_ slot: String, test: Bool, testUnit: String) -> String? {
        if test { return testUnit }
        let units = Bundle.main.object(forInfoDictionaryKey: "ZXAdUnits") as? [String: String] ?? [:]
        if let u = units[slot], u.range(of: #"^ca-app-pub-\d{16}/\d{10}$"#, options: .regularExpression) != nil { return u }
        return nil
    }

    private func event(_ ev: String, _ slot: String = "", _ extra: [String: Any] = [:]) {
        var o: [String: Any] = ["ev": ev, "slot": slot]
        extra.forEach { o[$0.key] = $0.value }
        host?.sendToPage("zxAdEvent", o)
    }

    private func setStatus(_ s: String) { host?.setNativeValue("ads", s) }

    private func errorExtra(_ e: Error) -> [String: Any] {
        let n = e as NSError
        return ["code": n.code, "msg": String(n.localizedDescription.prefix(200))]
    }

    // MARK: start: consent (UMP) → App Tracking Transparency → SDK

    func start() {
        if ready { event("ready"); return }
        if starting { return }
        starting = true; setStatus("starting")
        ConsentInformation.shared.requestConsentInfoUpdate(with: RequestParameters()) { [weak self] _ in
            guard let self = self, let vc = self.host else { return }
            ConsentForm.loadAndPresentIfRequired(from: vc) { [weak self] _ in self?.afterConsent() }
        }
    }

    private func afterConsent() {
        host?.setNativeValue("privacy", ConsentInformation.shared.privacyOptionsRequirementStatus == .required)
        guard ConsentInformation.shared.canRequestAds else {
            starting = false; setStatus("off"); event("noconsent"); return
        }
        let go = { [weak self] in
            MobileAds.shared.start { _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.ready = true; self.starting = false; self.setStatus("ready"); self.event("ready")
                }
            }
        }
        if #available(iOS 14.5, *), ATTrackingManager.trackingAuthorizationStatus == .notDetermined {
            // the system asks only while the app is active
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                ATTrackingManager.requestTrackingAuthorization { _ in DispatchQueue.main.async { go() } }
            }
        } else { go() }
    }

    func privacyOptions() {
        guard let vc = host else { return }
        ConsentForm.presentPrivacyOptionsForm(from: vc) { [weak self] _ in
            self?.host?.setNativeValue("privacy", ConsentInformation.shared.privacyOptionsRequirementStatus == .required)
        }
    }

    // MARK: banner (under the page)

    func showBanner(slot: String, test: Bool) {
        guard ready, let vc = host else { event("failed", slot, ["why": "notready"]); return }
        guard let u = unit(slot, test: test, testUnit: Self.testBanner) else { event("failed", slot, ["why": "nounit"]); return }
        hideBanner()
        let width = vc.view.bounds.width
        let b = BannerView(adSize: currentOrientationAnchoredAdaptiveBanner(width: width))
        b.adUnitID = u
        b.rootViewController = vc
        b.delegate = self
        banner = b; bannerSlot = slot
        vc.setBanner(b)
        b.load(Request())
    }

    func hideBanner() {
        banner?.removeFromSuperview(); banner = nil
        host?.setBanner(nil)
    }

    func bannerViewDidReceiveAd(_ bannerView: BannerView) { event("shown", bannerSlot) }

    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        let s = bannerSlot
        hideBanner()
        event("failed", s, errorExtra(error))
    }

    // MARK: full-screen ads

    func showInterstitial(slot: String, test: Bool) {
        guard ready else { event("failed", slot, ["why": "notready"]); return }
        guard let u = unit(slot, test: test, testUnit: Self.testInter) else { event("failed", slot, ["why": "nounit"]); return }
        InterstitialAd.load(with: u, request: Request()) { [weak self] ad, err in
            guard let self = self else { return }
            guard let ad = ad, let vc = self.host else { self.event("failed", slot, err.map(self.errorExtra) ?? [:]); return }
            ad.fullScreenContentDelegate = self
            self.showing[ObjectIdentifier(ad)] = (slot, false)
            self.live.append(ad)
            ad.present(from: vc)
        }
    }

    func showRewarded(slot: String, test: Bool) {
        guard ready else { event("failed", slot, ["why": "notready"]); return }
        guard let u = unit(slot, test: test, testUnit: Self.testReward) else { event("failed", slot, ["why": "nounit"]); return }
        RewardedAd.load(with: u, request: Request()) { [weak self] ad, err in
            guard let self = self else { return }
            guard let ad = ad, let vc = self.host else { self.event("failed", slot, err.map(self.errorExtra) ?? [:]); return }
            let id = ObjectIdentifier(ad)
            ad.fullScreenContentDelegate = self
            self.showing[id] = (slot, true)
            self.live.append(ad)
            ad.present(from: vc) { [weak self] in self?.earned.insert(id) }
        }
    }

    private func finish(_ ad: FullScreenPresentingAd) -> (slot: String, rewarded: Bool, earned: Bool)? {
        let id = ObjectIdentifier(ad)
        guard let s = showing.removeValue(forKey: id) else { return nil }
        let got = earned.remove(id) != nil
        live.removeAll { ObjectIdentifier($0) == id }
        return (s.slot, s.rewarded, got)
    }

    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        guard let s = finish(ad) else { return }
        event("closed", s.slot, s.rewarded ? ["earned": s.earned] : [:])
    }

    func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        guard let s = finish(ad) else { return }
        event("failed", s.slot, errorExtra(error))
    }
}
