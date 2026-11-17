import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.backgroundColor = WebViewController.bg
        let vc = WebViewController()
        if let url = launchOptions?[.url] as? URL { vc.pendingLink = WebViewController.gameQuery(url) }
        w.rootViewController = vc
        w.makeKeyAndVisible()
        window = w
        return true
    }

    // zigrax://g?m=...&w=...  (shared game links)
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        guard let q = WebViewController.gameQuery(url), let vc = window?.rootViewController as? WebViewController else { return false }
        vc.openGameLink(q)
        return true
    }
}
