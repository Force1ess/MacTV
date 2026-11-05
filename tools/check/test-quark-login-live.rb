#!/usr/bin/env ruby
# One anonymous challenge + one unscanned poll. No QR/token/account data is printed.
require 'json'
require 'open3'
require 'uri'
root = File.expand_path('../..', __dir__)
host = ARGV[0] || File.join(root, '.build/debug/MTVPluginHost')
plugin = File.join(root, 'src/integrations/quark')
def invoke(host, plugin, input)
  output, _error, status = Open3.capture3(host, plugin, stdin_data: JSON.generate(action: 'login', input: input))
  value = JSON.parse(output)
  raise 'Helper failed' unless status.success? && value['result']
  raise 'Unexpected account credential' if value['credential']
  value['result']
end
begin
  challenge = invoke(host, plugin, step: 'start')
  address = URI.parse(challenge.fetch('qrURL'))
  token = challenge.fetch('token')
  checks = {
    officialQRHost: address.scheme == 'https' && address.host == 'su.quark.cn',
    tokenBounded: token.match?(/\A[A-Za-z0-9_-]{16,128}\z/),
    expiryBounded: challenge.fetch('expiresAt').between?(Time.now.to_f, Time.now.to_f + 181)
  }
  raise 'Challenge invalid' unless checks.values.all?
  poll = invoke(host, plugin, step: 'poll', token: token)
  checks[:unscannedWaiting] = poll['state'] == 'waiting'
  puts JSON.pretty_generate(checks: checks, passed: checks.values.all?, accountAuthorized: false,
    tokenRecorded: false, serviceTicketExchangeVerified: false)
  exit(checks.values.all? ? 0 : 1)
rescue
  puts JSON.pretty_generate(passed: false, error: 'Live Quark challenge or unscanned poll failed; private response omitted',
    tokenRecorded: false, serviceTicketExchangeVerified: false)
  exit 1
end
