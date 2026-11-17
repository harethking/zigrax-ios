import Foundation
import WebKit

/// Only when launched with -zxSelfTest (the cloud build does this on the simulator): checks that the
/// page has everything it needs inside WKWebView and prints one line "ZXSELFTEST {...}".
enum SelfTest {
    /// the cloud build reads Documents/selftest.json from the simulator
    private static func save(_ s: String) {
        print("ZXSELFTEST \(s)"); fflush(stdout)
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? s.write(to: dir.appendingPathComponent("selftest.json"), atomically: true, encoding: .utf8)
        }
    }

    private static var done = false

    static func run(_ web: WKWebView) {
        if done { return }
        done = true
        let js = """
        const out = {};
        const t = (ms) => new Promise(r => setTimeout(r, ms));
        out.secure = window.isSecureContext;
        out.origin = location.origin;
        out.title = document.title;
        try { localStorage.setItem("zx_selftest", "1"); out.storage = localStorage.getItem("zx_selftest") === "1"; } catch (e) { out.storage = String(e); }
        out.bridge = !!(window.ZXAds && window.ZXiOS);
        out.mic = !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia);
        out.recorder = typeof MediaRecorder !== "undefined";
        out.wasm = typeof WebAssembly === "object";
        try { const r = await fetch("zx/book.json"); out.book = r.ok && (await r.text()).length > 100; } catch (e) { out.book = String(e); }
        try { const r = await fetch("zx/sf/stockfish-19-lite-single.wasm"); out.wasmType = r.headers.get("content-type"); out.wasmBytes = (await r.arrayBuffer()).byteLength; } catch (e) { out.wasmType = String(e); }
        try {
          out.stockfish = await new Promise((ok) => {
            const w = new Worker("zx/sf/stockfish-19-lite-single.js");
            const to = setTimeout(() => { ok("timeout"); w.terminate(); }, 20000);
            w.onmessage = (e) => { const s = String(e.data); if (s.indexOf("bestmove") === 0) { clearTimeout(to); ok(s); w.terminate(); } };
            w.onerror = (e) => { clearTimeout(to); ok("error " + (e.message || "")); };
            w.postMessage("uci"); w.postMessage("position startpos"); w.postMessage("go depth 8");
          });
        } catch (e) { out.stockfish = String(e); }
        try {
          const r = await fetch("https://kfiyrxabfycnftgnipqd.supabase.co/rest/v1/rpc/zx_ads_config", { method: "POST", headers: { "Content-Type": "application/json", "apikey": (window.SB_KEY || "") }, body: "{}" });
          out.network = r.status;
        } catch (e) { out.network = String(e); }
        await t(1500);
        out.splashGone = !document.getElementById("zxSplash");
        out.pageErrors = (window.__zxErrs || []).slice(0, 5);
        return JSON.stringify(out);
        """
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            web.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let v): save("\(v)")
                case .failure(let e): save("{\"error\":\"\(e.localizedDescription)\"}")
                }
            }
        }
    }
}
