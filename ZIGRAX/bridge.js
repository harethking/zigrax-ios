// Injected at document start by the iOS app. Gives the page the same window.ZXAds API the
// Android app has, plus window.ZXiOS (share sheet). Calls go to Swift through
// webkit.messageHandlers.zx; answers come back through window.zxAdEvent like on Android.
(function () {
  if (window.ZXiOS) return;
  window.__zxErrs = [];
  window.addEventListener("error", function (e) { if (window.__zxErrs.length < 20) window.__zxErrs.push(String(e.message || e)); });
  var post = function (m) { try { window.webkit.messageHandlers.zx.postMessage(m); } catch (e) { } };
  var st = { ads: "off", privacy: false };
  window.__zxNative = function (k, v) { st[k] = v; };   // Swift keeps these two values current
  window.ZXiOS = {
    platform: "ios",
    share: function (text) { post({ fn: "share", text: String(text || "") }); },
    open: function (url) { post({ fn: "open", url: String(url || "") }); }
  };
  // notifications: the same API as Android (see Push.swift); state() is kept current by Swift
  st.notif = "ask";
  window.ZXNotify = {
    state: function () { return st.notif || "ask"; },
    ask: function () { post({ fn: "ntAsk" }); },
    setup: function (json) { post({ fn: "ntSetup", json: String(json || "") }); },
    seen: function () { },
    test: function (t, b) { post({ fn: "ntTest", t: String(t || ""), b: String(b || "") }); }
  };
  // iOS checks no Chess.com / Lichess games in the background: hide that switch and its prompt
  document.addEventListener("DOMContentLoaded", function () {
    var cs = document.createElement("style");
    cs.textContent = "label.tgl:has(#ntGames),label.tgl:has(#ntGames)+.ntd,.ntask{display:none!important}";
    document.head.appendChild(cs);
  });
  window.ZXAds = {
    start: function () { post({ fn: "adsStart" }); },
    status: function () { return st.ads; },
    banner: function (slot, unit, test) { post({ fn: "banner", slot: String(slot || ""), test: !!test }); },
    hideBanner: function () { post({ fn: "hideBanner" }); },
    interstitial: function (slot, unit, test) { post({ fn: "interstitial", slot: String(slot || ""), test: !!test }); },
    rewarded: function (slot, unit, test) { post({ fn: "rewarded", slot: String(slot || ""), test: !!test }); },
    privacyNeeded: function () { return !!st.privacy; },
    privacyOptions: function () { post({ fn: "privacyOptions" }); }
  };
})();
