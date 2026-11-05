#!/usr/bin/env ruby
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'

# The ephemeral key stays in a mode-700 test directory. No keychain import,
# trust-store mutation, production app replacement, or permission grant occurs.
tool = ENV.fetch('MTV_RCODESIGN', File.expand_path('~/Developer/MTVDeveloper/Tools/rcodesign-0.29.0/rcodesign'))
abort 'Install the pinned rcodesign runtime first.' unless File.executable?(tool)
environment = ENV.keys.select { |name| name.start_with?('RCODESIGN_') }.to_h { |name| [name, nil] }
checks = {}
def invoke_private(environment, *command)
  _out, _err, status = Open3.capture3(environment, *command)
  raise "Signing fixture command failed (#{status.exitstatus || status.termsig})" unless status.success?
end
previous_umask = File.umask(0o077)
begin
  Dir.mktmpdir('mtv-file-signing-') do |root|
    identity = File.join(root, 'identity')
    invoke_private(environment, tool, '-C', '/dev/null', 'generate-self-signed-certificate',
      '--person-name', 'MTV Local Signing Fixture', '--country-name', 'CN', '--validity-days', '7', '--pem-filename', identity)
    checks['privateKeyFileIsOwnerOnly'] = File.stat(identity + '.key').mode & 0o077 == 0
    apps = %w[First Second].each_with_index.map do |name, index|
      path = File.join(root, name + '.app')
      FileUtils.mkdir_p(File.join(path, 'Contents', 'MacOS'))
      FileUtils.cp('/usr/bin/true', File.join(path, 'Contents', 'MacOS', 'Fixture'))
      File.write(File.join(path, 'Contents', 'Info.plist'), <<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.mtv.signing-fixture</string>
        <key>CFBundleExecutable</key><string>Fixture</string><key>CFBundleVersion</key><string>#{index + 1}</string></dict></plist>
      XML
      invoke_private(environment, tool, '-C', '/dev/null', 'sign', '--timestamp-url', 'none',
        '--pem-source', identity + '.crt', '--pem-source', identity + '.key', path)
      _, _, valid = Open3.capture3('/usr/bin/codesign', '--verify', '--deep', '--strict', path)
      checks[name + 'PassesAppleSignatureVerification'] = valid.success?
      _, _, runnable = Open3.capture3(File.join(path, 'Contents', 'MacOS', 'Fixture'))
      checks[name + 'RunsWithoutSystemTrustChanges'] = runnable.success?
      path
    end
    checker = File.expand_path('check-update-identity.rb', __dir__)
    _, _, compatible = Open3.capture3('ruby', checker, *apps)
    checks['DifferentVersionsPreserveSameCryptographicIdentity'] = compatible.success?
    req_out, req_err, req_status = Open3.capture3('/usr/bin/codesign', '-d', '-r-', apps[0])
    requirement = req_out + req_err
    checks['IdentityIsCertificateBoundRatherThanBareIdentifier'] = req_status.success? && requirement.include?('certificate') && !requirement.include?('designated => cdhash')
  end
  puts JSON.pretty_generate(checks: checks, passed: checks.values.all?, keychainChanged: false,
    systemTrustChanged: false, productionAppChanged: false, privacyPermissionPersistenceVerified: false)
  exit(checks.values.all? ? 0 : 1)
rescue StandardError => error
  warn error.message
  puts JSON.generate(passed: false, keychainChanged: false, systemTrustChanged: false, productionAppChanged: false)
  exit 1
ensure
  File.umask(previous_umask)
end
