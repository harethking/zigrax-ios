# Signing for the App Store build through the App Store Connect API (no Mac, no device needed).
#   ruby scripts/signing.rb setup    -> registers the bundle id if missing, makes a temporary Apple
#                                       Distribution certificate + App Store profile, installs both
#   ruby scripts/signing.rb cleanup  -> revokes that certificate and deletes the profile again
# Needs ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, KEYCHAIN, KEYCHAIN_PASS in the environment.
require "spaceship"
require "openssl"
require "base64"
require "json"
require "fileutils"

BUNDLE = "com.hareth.zigrax"
STATE = File.expand_path("~/zx_signing.json")

Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.create(
  key_id: ENV.fetch("ASC_KEY_ID"), issuer_id: ENV.fetch("ASC_ISSUER_ID"), filepath: ENV.fetch("ASC_KEY_PATH"))

def sh(*a) = system(*a) || abort("failed: #{a.first}")

case ARGV[0]
when "setup"
  bid = Spaceship::ConnectAPI::BundleId.find(BUNDLE)
  unless bid
    bid = Spaceship::ConnectAPI::BundleId.create(name: "ZIGRAX", platform: "IOS", identifier: BUNDLE)
    puts "registered bundle id #{BUNDLE}"
  end
  # push notifications must be on for the bundle id before the profile is made (the profile carries aps-environment)
  begin
    caps = bid.get_capabilities.map(&:capability_type)
    unless caps.include?("PUSH_NOTIFICATIONS")
      bid.create_capability(Spaceship::ConnectAPI::BundleIdCapability::Type::PUSH_NOTIFICATIONS)
      puts "push notifications turned on for #{BUNDLE}"
    end
  rescue => e
    warn "push capability: #{e.message}"
  end

  key = OpenSSL::PKey::RSA.new(2048)
  csr = OpenSSL::X509::Request.new
  csr.version = 0
  csr.subject = OpenSSL::X509::Name.parse("/CN=ZIGRAX CI/O=ZIGRAX/C=IQ")
  csr.public_key = key.public_key
  csr.sign(key, OpenSSL::Digest::SHA256.new)
  cert = Spaceship::ConnectAPI::Certificate.create(
    certificate_type: Spaceship::ConnectAPI::Certificate::CertificateType::DISTRIBUTION, csr_content: csr.to_pem)
  x509 = OpenSSL::X509::Certificate.new(Base64.decode64(cert.certificate_content))
  kc, pw = ENV.fetch("KEYCHAIN"), ENV.fetch("KEYCHAIN_PASS")
  File.write("/tmp/zx.key", key.to_pem)
  File.binwrite("/tmp/zx.cer", x509.to_der)
  sh("security", "import", "/tmp/zx.key", "-k", kc, "-t", "priv", "-f", "openssl", "-T", "/usr/bin/codesign", "-T", "/usr/bin/security")
  sh("security", "import", "/tmp/zx.cer", "-k", kc, "-t", "cert", "-f", "x509")
  sh("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", pw, kc, out: File::NULL)
  FileUtils.rm_f(["/tmp/zx.key", "/tmp/zx.cer"])

  name = "ZIGRAX App Store CI #{Time.now.utc.strftime('%Y%m%d%H%M%S')}"
  prof = Spaceship::ConnectAPI::Profile.create(
    name: name, profile_type: Spaceship::ConnectAPI::Profile::ProfileType::IOS_APP_STORE,
    bundle_id_id: bid.id, certificate_ids: [cert.id])
  dir = File.expand_path("~/Library/MobileDevice/Provisioning Profiles")
  FileUtils.mkdir_p(dir)
  File.binwrite(File.join(dir, "#{prof.uuid}.mobileprovision"), Base64.decode64(prof.profile_content))
  File.write(STATE, JSON.dump(cert: cert.id, profile: prof.id))
  File.open(ENV.fetch("GITHUB_ENV"), "a") { |f| f.puts("ZX_PROFILE_NAME=#{name}", "ZX_PROFILE_UUID=#{prof.uuid}") } if ENV["GITHUB_ENV"]
  puts "certificate and profile ready: #{name}"
when "cleanup"
  s = JSON.parse(File.read(STATE)) rescue nil
  exit 0 unless s
  (Spaceship::ConnectAPI.delete_profile(profile_id: s["profile"]) rescue warn("profile: #{$!}"))
  (Spaceship::ConnectAPI.delete_certificate(certificate_id: s["cert"]) rescue warn("certificate: #{$!}"))
  FileUtils.rm_f(STATE)
  puts "temporary certificate revoked, profile deleted"
else
  abort "usage: signing.rb setup|cleanup"
end
