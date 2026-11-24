import UIKit
import UserNotifications

/// iPhone notifications, behind the same window.ZXNotify API the Android app gives the page:
///  • Apple push (messages, friend requests, game invites, admin news): the phone's token is saved by the
///    zx-notify server function together with the user's private topic and texts in the phone's language.
///  • the daily reminder: local notifications for the next 7 days (re-planned every time the app opens,
///    so a day on which the app was opened gets none).
final class Push: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Push()
    weak var host: WebViewController?

    private let fnURL = URL(string: "https://kfiyrxabfycnftgnipqd.supabase.co/functions/v1/zx-notify")!
    private let anonKey = "sb_publishable_7xa36Al56_Zr3YvG58FY8A_u-JpKSvs"   // public key, the same one the page uses
    private var cfg: [String: Any] = [:]
    private var token: String? = UserDefaults.standard.string(forKey: "zx_apns_token")
    private var pendingOpen: String?
    private(set) var state = "ask"

    func start() {
        UNUserNotificationCenter.current().delegate = self
        refreshState { granted in if granted { DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() } } }
    }

    // MARK: page → app

    func handle(_ m: [String: Any]) {
        switch m["fn"] as? String ?? "" {
        case "ntAsk": ask()
        case "ntSetup":
            if let s = m["json"] as? String, let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                cfg = o; apply()
            }
        case "ntTest": test(m["t"] as? String ?? "ZIGRAX", m["b"] as? String ?? "")
        default: break
        }
    }

    func pageReady() {
        host?.setNativeValue("notif", state)
        if let p = pendingOpen { pendingOpen = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.host?.callPage("zxNotifOpen", p) } }
    }

    private func refreshState(_ done: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let st: String
            switch s.authorizationStatus {
            case .authorized, .provisional, .ephemeral: st = "granted"
            case .denied: st = "denied"
            default: st = "ask"
            }
            DispatchQueue.main.async {
                self.state = st
                self.host?.setNativeValue("notif", st)
                done?(st == "granted")
            }
        }
    }

    private func ask() {
        if state == "denied" {   // iOS asks only once: after a "no" the switch is in Settings
            if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            self.refreshState { granted in
                if granted { UIApplication.shared.registerForRemoteNotifications() }
                self.host?.sendToPage("zxNotifyEvent", ["granted": granted])
                self.apply()
            }
        }
    }

    // MARK: Apple token

    func gotToken(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        if hex != token { token = hex; UserDefaults.standard.set(hex, forKey: "zx_apns_token"); UserDefaults.standard.removeObject(forKey: "zx_apns_sent") }
        sync()
    }

    private func apply() {
        if !cfg.isEmpty { sync(); planDaily() }
    }

    /// tells the server what this phone wants (only when something changed)
    private func sync() {
        guard let tok = token, !cfg.isEmpty else { return }
        let on = (cfg["on"] as? Bool ?? false) && state == "granted"
        let txt = cfg["txt"] as? [String: Any] ?? [:]
        var keep: [String: String] = [:]
        for k in ["p_msg_t", "p_msg_many", "p_freq", "p_fok", "p_inv"] { if let v = txt[k] as? String { keep[k] = v } }
        let body: [String: Any] = ["op": "apns", "token": tok, "on": on, "ut": cfg["ut"] as? String ?? "",
                                   "news": cfg["news"] as? Bool ?? true, "msgs": cfg["msgs"] as? Bool ?? true,
                                   "lang": Locale.preferredLanguages.first ?? "", "txt": keep]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return }
        let key = "zx_apns_sent"
        if let last = UserDefaults.standard.dictionary(forKey: key), last["s"] as? String == String(decoding: data, as: UTF8.self),
           let at = last["at"] as? Double, Date().timeIntervalSince1970 - at < 7 * 86400 { return }
        var req = URLRequest(url: fnURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.httpBody = data
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            if (resp as? HTTPURLResponse)?.statusCode == 200 {
                UserDefaults.standard.set(["s": String(decoding: data, as: UTF8.self), "at": Date().timeIntervalSince1970], forKey: key)
            }
        }.resume()
    }

    // MARK: local notifications

    private func planDaily() {
        let c = UNUserNotificationCenter.current()
        let ids = (1...7).map { "zx_daily_\($0)" }
        c.removePendingNotificationRequests(withIdentifiers: ids)
        guard (cfg["on"] as? Bool ?? false), state == "granted", cfg["daily"] as? Bool ?? false else { return }
        let txt = cfg["txt"] as? [String: Any] ?? [:]
        let hour = max(0, min(23, (cfg["hour"] as? NSNumber)?.intValue ?? 20))
        let cal = Calendar.current
        for i in 1...7 {
            guard let day = cal.date(byAdding: .day, value: i, to: Date()) else { continue }
            var dc = cal.dateComponents([.year, .month, .day], from: day)
            dc.hour = hour; dc.minute = 0
            let k = i % 3
            let n = UNMutableNotificationContent()
            n.title = txt["daily_t\(k)"] as? String ?? "ZIGRAX ♟"
            n.body = txt["daily_b\(k)"] as? String ?? ""
            n.sound = .default
            n.userInfo = ["zxopen": "puzzles"]
            c.add(UNNotificationRequest(identifier: ids[i - 1], content: n, trigger: UNCalendarNotificationTrigger(dateMatching: dc, repeats: false)))
        }
    }

    private func test(_ t: String, _ b: String) {
        guard state == "granted" else { ask(); return }
        let n = UNMutableNotificationContent()
        n.title = t; n.body = b; n.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "zx_test", content: n, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)))
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        if #available(iOS 14.0, *) { done([.banner, .list, .sound]) } else { done([.alert, .sound]) }
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        let open = r.notification.request.content.userInfo["zxopen"] as? String ?? ""
        if !open.isEmpty, open.range(of: "^[a-z]{1,20}$", options: .regularExpression) != nil {
            if let h = host, h.isPageReady { h.callPage("zxNotifOpen", open) } else { pendingOpen = open }
        }
        done()
    }
}
