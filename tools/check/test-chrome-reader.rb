#!/usr/bin/env ruby
# Tests the signed component directly from an untrusted parent. It must never
# touch the keychain or return a secret in this situation.
require 'json'
require 'open3'
helper = ARGV.fetch(0, '/Applications/MacTV.app/Contents/MacOS/MTVChromeBridge')
checks = {}
version, _, status = Open3.capture3(helper, '--chrome-reader-version')
v = JSON.parse(version)
checks['componentHasVersionedProtocol'] = status.success? && v['component'] == 'chrome-reader' && v['version'] == 1
%w[--no-ui --allow-ui].each do |mode|
  stdout, _stderr, result = Open3.capture3(helper, '--chrome-storage-read', mode)
  value = JSON.parse(stdout)
  checks[mode + '-rejectsUntrustedParentBeforeKeychainRead'] = result.success? && value['reason'] == 'untrusted-parent' && value['status'] != 0
  checks[mode + '-neverReturnsSecret'] = stdout.bytesize < 512 && !value.key?('secret')
end
stdout, _, status = Open3.capture3(helper, '--chrome-storage-read', '--unknown')
checks['malformedReaderArgumentsCannotLaunchMainApp'] = status.success? && JSON.parse(stdout)['reason'] == 'invalid-reader-arguments'
puts JSON.pretty_generate(checks: checks, passed: checks.values.all?, realAccountRead: false)
exit(checks.values.all? ? 0 : 1)
