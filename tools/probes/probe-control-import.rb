#!/usr/bin/env ruby
# Explicit real import through MTV itself. Never opens browser files or echoes sessions.
require 'json'
require 'open3'

provider, profile = ARGV
abort 'Usage: probe-control-import.rb mtv.quark|mtv.bilibili [PROFILE_TITLE]' unless %w[mtv.quark mtv.bilibili].include?(provider)
cli = '/Applications/MacTV.app/Contents/MacOS/mtvctl'
class ControlNotReady < StandardError; end
def control(cli, command, arguments = {})
  output, stderr, status = Open3.capture3(cli, 'call', JSON.generate(command: command, arguments: arguments))
  result = JSON.parse(output.empty? ? stderr : output)
  if %w[control-not-running-or-unsafe control-connection-rejected].include?(result['error'])
    raise ControlNotReady, 'Control endpoint is not ready'
  end
  raise 'Control command failed' unless status.success? && result['ok']
  result
end
begin
  ready_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
  initial = nil
  loop do
    begin
      initial = control(cli, 'status').fetch('state')
      break if initial.fetch('accounts', []).any? { |account| account['plugin'] == provider }
      raise ControlNotReady, 'Provider catalog is not ready'
    rescue ControlNotReady
      raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= ready_deadline
      sleep 0.1
    end
  end
  raise 'Account import is not explicitly enabled' unless initial['accountImportEnabled']
  receipt = control(cli, 'account.importChrome', {'plugin'=>provider})
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 25
  selected = false
  loop do
    state = control(cli, 'status').fetch('state')
    raise 'App run changed during import' unless state['pid'] == initial['pid'] && state['controlRunID'] == initial['controlRunID']
    login = state.fetch('login')
    raise 'Import provider changed during verification' unless login['plugin'] == provider
    if login['state'] == 'chromeProfiles' && !login['chromeProfilesUnavailable'] && profile && !selected
      raise 'Requested profile is not listed' unless login.fetch('chromeProfiles').include?(profile)
      control(cli, 'account.selectProfile', {'plugin'=>provider, 'name'=>profile})
      selected = true
      next
    end
    terminal = %w[authorized failed chromeProfiles chromeAuthorization].include?(login['state'])
    if terminal || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      verified = login['state'] == 'authorized' && login['platformVerifiedThisRun'] == true
      puts JSON.pretty_generate(schema: 1, provider: provider, pid: state['pid'], controlRunID: state['controlRunID'],
        requestID: receipt['id'], accepted: receipt['accepted'], platformVerified: verified,
        elapsedSeconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
        state: login['state'], diagnostic: login['chromeImportDiagnostic'], message: login['message'],
        selectionRequired: login['state'] == 'chromeProfiles' && !login['chromeProfilesUnavailable'],
        profiles: login['chromeProfiles'], credentialsPrinted: false)
      exit(verified ? 0 : 2)
    end
    sleep 0.2
  end
rescue StandardError => failure
  safe_reasons = ['Control command failed', 'Account import is not explicitly enabled', 'App run changed during import',
    'Import provider changed during verification', 'Requested profile is not listed', 'Control endpoint is not ready', 'Provider catalog is not ready']
  line = failure.backtrace&.map { |value| value[/probe-control-import\.rb:(\d+)/, 1] }&.compact&.first
  puts JSON.pretty_generate(schema: 1, provider: provider, platformVerified: false,
    error: 'Import probe could not complete; inspect current MTV state/events', failureClass: failure.class.name,
    reason: safe_reasons.include?(failure.message) ? failure.message : 'See failure class and probe line', probeLine: line&.to_i,
    credentialsPrinted: false)
  exit 1
end
