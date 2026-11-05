#!/usr/bin/env ruby
require 'json'
require 'open3'
require 'uri'

root = File.expand_path('../..', __dir__)
host = ARGV.first || File.join(root, '.build/debug/MTVPluginHost')
plugin = ARGV[1] || File.join(root, 'src/integrations/bilibili')
def invoke(host, plugin, input)
  stdout, _stderr, status = Open3.capture3(host, plugin, stdin_data: JSON.generate(action: 'login', input: input))
  value = JSON.parse(stdout)
  raise(value['error'] || 'Login helper failed') unless status.success? && value['result']
  value['result']
end
secrets = []
begin
  generated = invoke(host, plugin, step: 'start')
  secrets = [generated['qrURL'], generated['token']].select { |value| value.is_a?(String) && !value.empty? }
  checks = {}
  url = URI.parse(generated.fetch('qrURL'))
  checks['officialQRDomain'] = url.scheme == 'https' && ['passport.bilibili.com', 'account.bilibili.com'].include?(url.host)
  checks['challengeHasBoundedExpiry'] = generated.fetch('expiresAt') > Time.now.to_f && generated['expiresAt'] <= Time.now.to_f + 181
  checks['challengeTokenShape'] = generated.fetch('token').match?(/\A[a-fA-F0-9]{32}\z/)
  update = invoke(host, plugin, step: 'poll', token: generated['token'])
  checks['unscannedState'] = update['state'] == 'waiting'
  puts JSON.pretty_generate(checks: checks, passed: checks.values.all?, accountAuthorized: update['state'] == 'authorized', tokenRecorded: false)
  exit(checks.values.all? ? 0 : 1)
rescue => error
  message = if error.is_a?(JSON::ParserError) || error.is_a?(URI::InvalidURIError)
    '登录响应解析失败，内容未记录'
  else
    secrets.reduce(error.message) { |text, secret| text.gsub(secret, '[redacted]') }
  end
  puts JSON.pretty_generate(passed: false, error: message, accountAuthorized: false, tokenRecorded: false)
  exit(1)
end
