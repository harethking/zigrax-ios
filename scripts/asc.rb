# App Store Connect listing settings through the official API (no website session needed).
#   ruby scripts/asc.rb setup    -> privacy policy URL, age rating, free price in every country,
#                                   export compliance on the build, release after approval, status report
#   ruby scripts/asc.rb submit   -> sends version VERSION for App Review
#   ruby scripts/asc.rb release  -> new version VERSION: what's new text, waits for the uploaded build,
#                                   attaches it, release after approval, then sends it for App Review
# Needs ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH in the environment.
require "openssl"
require "base64"
require "json"
require "net/http"
require "uri"

APP = "6835940613"
VERSION = "1.0.19"
# App Store search keywords (max 100 characters, no spaces, no words already in the app name, no other apps' names)
KEYWORDS = "شطرنج,chess,stockfish,ستوكفيش,ألغاز,لغز,puzzles,افتتاحيات,openings,zigrax,بطولات,مباريات,كش,ملك"
WHATS_NEW = {
  "ar" => "• تلميح الافتتاحيات يعمل مع الإعلانات على الآيفون
• إعلان التحليل لا يظهر فارغاً
• شجرة افتتاح أوضح والرقعة بحجمها الكامل في الشجرة والأفخاخ
• تحسينات وإصلاحات",
  "en" => "• Openings hint works with ads on iPhone
• No more empty ad box while analysing
• Clearer opening tree, full-size board in tree and traps
• Improvements and fixes"
}
PRIVACY = "https://zigrax-legal.vercel.app/privacy-policy.html"
SUBTITLE = "تحليل وألغاز وافتتاحيات"

def b64(s) = Base64.urlsafe_encode64(s, padding: false)

def token
  require "spaceship"
  @tok ||= Spaceship::ConnectAPI::Token.create(key_id: ENV.fetch("ASC_KEY_ID"), issuer_id: ENV.fetch("ASC_ISSUER_ID"), filepath: ENV.fetch("ASC_KEY_PATH"))
  @tok.refresh! if @tok.expired?
  @tok.text
end

def api(method, path, body = nil)
  uri = URI(path.start_with?("http") ? path : "https://api.appstoreconnect.apple.com#{path}")
  req = Net::HTTP.const_get(method.capitalize).new(uri)
  req["Authorization"] = "Bearer #{token}"
  req["Content-Type"] = "application/json"
  req.body = body.to_json if body
  res = nil
  8.times do |n|
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
    break unless res.code.to_i == 401 || res.code.to_i >= 500
    sleep 6 * (n + 1)   # Apple's sign-in service is recovering from an outage: retry with a fresh token
    @tok = nil
    req["Authorization"] = "Bearer #{token}"
  end
  data = res.body.to_s.empty? ? {} : JSON.parse(res.body)
  unless res.code.to_i < 300
    errs = (data["errors"] || []).map { |e| "#{e['code']}: #{e['detail']} #{e.dig('source', 'pointer')}" }
    return { "error" => res.code, "errors" => errs }
  end
  data
end

def ok(label, r)
  if r["error"] then puts "✗ #{label}: #{r['error']} #{r['errors'].join(' | ')}"; false
  else puts "✓ #{label}"; true end
end

def all(path)
  out = []
  url = path
  while url
    r = api("GET", url)
    raise "GET #{path}: #{r['errors']}" if r["error"]
    out.concat(r["data"])
    url = r.dig("links", "next")
  end
  out
end

def version
  all("/v1/apps/#{APP}/appStoreVersions?filter[platform]=IOS").find { |v| v.dig("attributes", "versionString") == VERSION }
end

case ARGV[0]
when "setup"
  # 1. privacy policy URL (+ subtitle) on every listing language of the editable app info
  infos = all("/v1/apps/#{APP}/appInfos")
  info = infos.find { |i| %w[PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED].include?(i.dig("attributes", "appStoreState") || i.dig("attributes", "state")) } || infos.first
  puts "app info #{info['id']} #{info['attributes'].slice('appStoreState', 'state', 'appStoreAgeRating').to_json}"
  all("/v1/appInfos/#{info['id']}/appInfoLocalizations").each do |l|
    a = l["attributes"]
    attrs = { privacyPolicyUrl: PRIVACY }
    attrs[:subtitle] = SUBTITLE if a["locale"].start_with?("ar")
    ok("privacy URL #{a['locale']} (subtitle was #{a['subtitle'].inspect})",
       api("PATCH", "/v1/appInfoLocalizations/#{l['id']}", { data: { type: "appInfoLocalizations", id: l["id"], attributes: attrs } }))
  end

  # 2. age rating: no objectionable content; players can chat with each other and the app shows ads
  ar = api("GET", "/v1/appInfos/#{info['id']}/ageRatingDeclaration")
  if ar["error"]
    puts "✗ age rating read: #{ar['errors'].join(' | ')}"
  else
    cur = ar.dig("data", "attributes")
    puts "age rating fields: #{cur.keys.join(',')}"
    want = {}
    cur.each_key do |k|
      want[k] =
        case k
        when "messagingAndChat", "userGeneratedContent", "advertising" then true
        when "socialMedia", "socialMediaAgeRestricted" then false
        when "gracRatingClassificationNumber" then nil
        when "gambling", "lootBox", "unrestrictedWebAccess", "seventeenPlus", "ageAssurance",
             "parentalControls", "healthOrWellnessTopics" then false
        when "kidsAgeBand", "ageRatingOverride", "ageRatingOverrideV2", "koreaAgeRatingOverride", "developerAgeRatingInfoUrl" then nil
        else cur[k].is_a?(TrueClass) || cur[k].is_a?(FalseClass) ? false : "NONE"
        end
    end
    want.delete_if { |k, v| v.nil? }
    r = api("PATCH", "/v1/ageRatingDeclarations/#{ar.dig('data', 'id')}", { data: { type: "ageRatingDeclarations", id: ar.dig("data", "id"), attributes: want } })
    if !ok("age rating", r)
      # drop fields the API refuses and try again
      bad = r["errors"].join(" ").scan(%r{/data/attributes/(\w+)}).flatten
      bad.each { |b| want.delete(b) }
      ok("age rating (without #{bad.join(',')})", api("PATCH", "/v1/ageRatingDeclarations/#{ar.dig('data', 'id')}", { data: { type: "ageRatingDeclarations", id: ar.dig("data", "id"), attributes: want } })) unless bad.empty?
    end
  end

  # 3. price: free, base country USA
  free = (all("/v1/apps/#{APP}/appPricePoints?filter[territory]=USA&limit=200").find { |p| p.dig("attributes", "customerPrice").to_f == 0.0 } rescue (puts "✗ price points: #{$!.message[0,200]}"; nil))
  if free
    ok("price free", api("POST", "/v1/appPriceSchedules", {
      data: { type: "appPriceSchedules",
              relationships: { app: { data: { type: "apps", id: APP } },
                               baseTerritory: { data: { type: "territories", id: "USA" } },
                               manualPrices: { data: [{ type: "appPrices", id: "${p0}" }] } } },
      included: [{ type: "appPrices", id: "${p0}", attributes: { startDate: nil },
                   relationships: { appPricePoint: { data: { type: "appPricePoints", id: free["id"] } } } }] }))
  else
    puts "✗ no free price point found"
  end

  # 4. available in every country (and new ones later)
  terr = (all("/v1/territories?limit=200").map { |t| t["id"] } rescue (puts "✗ territories: #{$!.message[0,200]}"; []))
  r = terr.empty? ? { "error" => "skip", "errors" => [] } : api("POST", "/v2/appAvailabilities", {
    data: { type: "appAvailabilities", attributes: { availableInNewTerritories: true },
            relationships: { app: { data: { type: "apps", id: APP } },
                             territoryAvailabilities: { data: terr.each_with_index.map { |_, i| { type: "territoryAvailabilities", id: "${t#{i}}" } } } } },
    included: terr.each_with_index.map { |t, i| { type: "territoryAvailabilities", id: "${t#{i}}", attributes: { available: true },
                                                  relationships: { territory: { data: { type: "territories", id: t } } } } } })
  ok("available in #{terr.size} countries", r) || puts("  (availability may already exist; check below)")

  # 5. version: release after approval, build export compliance
  v = version
  if v
    ok("release automatically after approval", api("PATCH", "/v1/appStoreVersions/#{v['id']}", { data: { type: "appStoreVersions", id: v["id"], attributes: { releaseType: "AFTER_APPROVAL" } } }))
    b = api("GET", "/v1/appStoreVersions/#{v['id']}/build")
    if (bd = b["data"])
      puts "build #{bd.dig('attributes', 'version')} state=#{bd.dig('attributes', 'processingState')} encryption=#{bd.dig('attributes', 'usesNonExemptEncryption').inspect}"
      if bd.dig("attributes", "usesNonExemptEncryption").nil?
        ok("export compliance (standard HTTPS only)", api("PATCH", "/v1/builds/#{bd['id']}", { data: { type: "builds", id: bd["id"], attributes: { usesNonExemptEncryption: false } } }))
      end
    else
      puts "✗ no build attached to #{VERSION}"
    end
  end

  # status report
  v = version
  puts "version #{VERSION}: #{v&.dig('attributes').to_h.slice('appStoreState', 'appVersionState', 'releaseType').to_json}"
  av = api("GET", "/v1/apps/#{APP}/appAvailabilityV2")
  puts "availability: #{av['error'] ? av['errors'].join(' | ') : av.dig('data', 'attributes').to_json}"
  ps = api("GET", "/v1/apps/#{APP}/appPriceSchedule")
  puts "price schedule: #{ps['error'] ? ps['errors'].join(' | ') : 'set'}"
  ar2 = api("GET", "/v1/appInfos/#{info['id']}/ageRatingDeclaration")
  puts "age rating now: #{ar2.dig('data', 'attributes').to_json}" unless ar2["error"]
when "status"
  all("/v1/apps/#{APP}/appStoreVersions?limit=5").each { |v| puts "#{v.dig('attributes', 'versionString')}: #{v.dig('attributes', 'appStoreState')}" }
when "release"
  # 1. the version (created if missing) and its "what's new" text
  v = version
  unless v
    r = api("POST", "/v1/appStoreVersions", { data: { type: "appStoreVersions", attributes: { platform: "IOS", versionString: VERSION, releaseType: "AFTER_APPROVAL" },
                                                      relationships: { app: { data: { type: "apps", id: APP } } } } })
    ok("version #{VERSION} created", r) or exit 1
    v = r["data"]
  end
  ok("release automatically after approval", api("PATCH", "/v1/appStoreVersions/#{v['id']}", { data: { type: "appStoreVersions", id: v["id"], attributes: { releaseType: "AFTER_APPROVAL" } } }))
  all("/v1/appStoreVersions/#{v['id']}/appStoreVersionLocalizations").each do |l|
    loc = l.dig("attributes", "locale")
    txt = loc.start_with?("ar") ? WHATS_NEW["ar"] : WHATS_NEW["en"]
    ok("what's new #{loc}", api("PATCH", "/v1/appStoreVersionLocalizations/#{l['id']}", { data: { type: "appStoreVersionLocalizations", id: l["id"], attributes: { whatsNew: txt, marketingUrl: "https://zigrax.com", keywords: KEYWORDS } } }))   # marketing URL = developer website: AdMob reads zigrax.com/app-ads.txt
  end
  # 2. wait for the uploaded build of this version to finish processing (up to ~35 min)
  bd = nil
  70.times do
    bs = all("/v1/builds?filter[app]=#{APP}&filter[preReleaseVersion.version]=#{VERSION}&sort=-uploadedDate&limit=5")
    bd = bs.find { |b| b.dig("attributes", "processingState") == "VALID" }
    puts "builds: #{bs.map { |b| "#{b.dig('attributes', 'version')}=#{b.dig('attributes', 'processingState')}" }.join(', ')}"
    break if bd || bs.any? { |b| %w[FAILED INVALID].include?(b.dig("attributes", "processingState")) }
    sleep 30
  end
  abort("no processed build for #{VERSION}") unless bd
  if bd.dig("attributes", "usesNonExemptEncryption").nil?
    ok("export compliance (standard HTTPS only)", api("PATCH", "/v1/builds/#{bd['id']}", { data: { type: "builds", id: bd["id"], attributes: { usesNonExemptEncryption: false } } }))
  end
  ok("build #{bd.dig('attributes', 'version')} attached", api("PATCH", "/v1/appStoreVersions/#{v['id']}/relationships/build", { data: { type: "builds", id: bd["id"] } })) or exit 1
  # 3. send it for review
  open = all("/v1/reviewSubmissions?filter[app]=#{APP}&filter[platform]=IOS").find { |s| %w[READY_FOR_REVIEW UNRESOLVED_ISSUES].include?(s.dig("attributes", "state")) }
  sub = open || api("POST", "/v1/reviewSubmissions", { data: { type: "reviewSubmissions", attributes: { platform: "IOS" }, relationships: { app: { data: { type: "apps", id: APP } } } } })["data"]
  abort("could not open a review submission") unless sub
  if all("/v1/reviewSubmissions/#{sub['id']}/items").empty?
    ok("version added", api("POST", "/v1/reviewSubmissionItems", { data: { type: "reviewSubmissionItems", relationships: {
      reviewSubmission: { data: { type: "reviewSubmissions", id: sub["id"] } }, appStoreVersion: { data: { type: "appStoreVersions", id: v["id"] } } } } })) or exit 1
  end
  ok("SENT FOR REVIEW", api("PATCH", "/v1/reviewSubmissions/#{sub['id']}", { data: { type: "reviewSubmissions", id: sub["id"], attributes: { submitted: true } } })) or exit 1
  puts "version #{VERSION}: #{version&.dig('attributes').to_h.slice('appStoreState', 'appVersionState').to_json}"
when "submit"
  v = version or abort("no version #{VERSION}")
  open = all("/v1/reviewSubmissions?filter[app]=#{APP}&filter[platform]=IOS").find { |s| %w[READY_FOR_REVIEW UNRESOLVED_ISSUES].include?(s.dig("attributes", "state")) }
  sub = open || api("POST", "/v1/reviewSubmissions", { data: { type: "reviewSubmissions", attributes: { platform: "IOS" }, relationships: { app: { data: { type: "apps", id: APP } } } } })["data"]
  abort("could not open a review submission") unless sub
  puts "submission #{sub['id']} #{sub.dig('attributes', 'state')}"
  items = all("/v1/reviewSubmissions/#{sub['id']}/items")
  if items.empty?
    ok("version added", api("POST", "/v1/reviewSubmissionItems", { data: { type: "reviewSubmissionItems", relationships: {
      reviewSubmission: { data: { type: "reviewSubmissions", id: sub["id"] } }, appStoreVersion: { data: { type: "appStoreVersions", id: v["id"] } } } } })) or exit 1
  end
  ok("SENT FOR REVIEW", api("PATCH", "/v1/reviewSubmissions/#{sub['id']}", { data: { type: "reviewSubmissions", id: sub["id"], attributes: { submitted: true } } })) or exit 1
  puts "version #{VERSION}: #{version&.dig('attributes').to_h.slice('appStoreState', 'appVersionState').to_json}"
else
  abort "usage: asc.rb setup|submit|release|status"
end
