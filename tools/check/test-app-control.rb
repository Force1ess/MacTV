#!/usr/bin/env ruby
# Exercises the running app's real model via its local control interface.
# No screenshots, browser databases, cookies, credentials or OS permission edits.
require 'json'
require 'open3'

options = ARGV.dup
disabled_test = options.delete('--expect-disabled')
require_posters = options.delete('--require-posters')
cli = options[0] || '/Applications/MacTV.app/Contents/MacOS/mtvctl'
expected_pid = options[1] && Integer(options[1])
checks = {}
anonymous_challenge_requested = false
class ControlNotReady < StandardError; end
def call(cli, command, arguments = {}, expected_ok: true)
  stdout, stderr, process = Open3.capture3(cli, 'call', JSON.generate(command: command, arguments: arguments))
  result = JSON.parse(stdout.empty? ? stderr : stdout)
  if expected_ok && %w[control-not-running-or-unsafe control-connection-rejected].include?(result['error'])
    raise ControlNotReady, 'App control endpoint is not ready'
  end
  raise 'Unexpected control command outcome' unless result['ok'] == expected_ok && process.success? == expected_ok
  result
end
def wait_state(cli)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 40
  loop do
    state = call(cli, 'status').fetch('state')
    return state if yield(state)
    raise 'App state did not reach the expected condition' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.1
  end
end
initial = nil
begin
  if disabled_test
    raise 'Disabled-mode verification requires the new PID' unless expected_pid
    command, process = Open3.capture2('ps','-p',expected_pid.to_s,'-o','comm=')
    arguments, _ = Open3.capture2('ps','-p',expected_pid.to_s,'-o','args=')
    stdout, stderr, result = Open3.capture3(cli,'status')
    error = JSON.parse(stdout.empty? ? stderr : stdout)
    checks['normalAppIsActuallyRunning'] = process.success? && command.strip == '/Applications/MacTV.app/Contents/MacOS/MTV'
    checks['normalLaunchDoesNotEnableControl'] = !arguments.split.include?('--enable-control')
    checks['CLIRejectsDisabledEndpointInsteadOfReadingOldState'] = !result.success? && %w[control-not-running-or-unsafe control-connection-rejected].include?(error['error'])
    puts JSON.pretty_generate(schema:1, scope:'normal-launch-control-disabled', checks:checks, passed:checks.values.all?)
    exit(checks.values.all? ? 0 : 1)
  end
  ready_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
  loop do
    begin
      initial = call(cli, 'status').fetch('state')
      break
    rescue ControlNotReady
      raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= ready_deadline
      sleep 0.1
    end
  end
  raise 'Control endpoint belongs to another app run' if expected_pid && initial['pid'] != expected_pid
  raise 'Close active playback or overlays before this test' if initial.dig('playback', 'presented') || initial.dig('playback', 'preparing') || !initial.fetch('overlays').empty?
  checks['runningInstalledAppReportsBuildAndPID'] = initial['pid'].is_a?(Integer) && !initial['build'].to_s.empty? && initial['phase'] == 'running'
  unless initial['visualExportEnabled']
    blocked_visual = call(cli,'visual.export',{'purpose'=>'layout'},expected_ok:false)
    checks['visualExportRequiresSeparateExplicitOption'] = blocked_visual['error']=='visual-export-not-enabled'
  end
  settings = call(cli, 'settings.list').dig('result', 'groups')
  checks['settingsAreDiscoverableAsUserTextAndStableIDs'] = settings.is_a?(Array) && settings.flat_map { |g| g.fetch('items') }.any? { |s| s['id'] == 'appearance' && !s['title'].empty? }
  %w[backspace escape].each do |key|
    call(cli, 'settings.open', {'id'=>'appearance'})
    opened = call(cli, 'status').fetch('state')
    checks[key + 'OpensActualAppearancePanel'] = opened.fetch('overlays').include?('appearance')
    closed = call(cli, 'input.key', {'key'=>key}).fetch('state')
    checks[key + 'ReturnsOneLevelThroughActualHandler'] = !closed.fetch('overlays').include?('appearance') && closed['section'] == 'settings'
  end
  call(cli, 'navigate', {'section'=>'library'})
  ready = wait_state(cli) { |s| !s.dig('library', 'refreshing') && s.dig('library', 'files').to_i > 0 }
  listing = call(cli, 'library.list', {'limit'=>'10'}).fetch('result')
  checks['currentLibraryHasRealDiscoverableItems'] = listing['total'].to_i > 0 && listing['items'].is_a?(Array)
  checks['listsNeverExposeResolvedURLs'] = listing['items'].all? { |i| !i.key?('url') && !i.key?('poster') }
  first = listing['items'].find { |i| i['addressable'] }
  described = call(cli, 'item.describe', {'id'=>first.fetch('id')}).dig('result','item')
  checks['individualItemsExposeTextWithoutStartingPlayback'] = described['id'] == first['id'] && described['title'].length >= first['title'].length && call(cli,'status').dig('state','playback','presented') == false
  refresh = call(cli, 'library.refresh')
  checks['refreshReportsAcceptanceInsteadOfClaimingCompletion'] = refresh['accepted'] == true
  job = refresh.dig('result', 'job')
  checks['refreshHasAnExplicitJobID'] = job.is_a?(String) && !job.empty?
  after = wait_state(cli) { |s| !s.dig('library', 'refreshing') && s.dig('libraryScan','id') == job && s.dig('libraryScan','phase') == 'completed' }
  checks['refreshFinishesWithActualSourceStillPresent'] = after.dig('library', 'files') == ready.dig('library', 'files')
  checks['freshScanEvidenceDoesNotComeFromOldCache'] = after.dig('libraryScan','entries') == ready.dig('library','files') && after.dig('libraryScan','limited') == false
  checks['freshScanShowsNoUnavailableFiles'] = after.dig('libraryScan','unavailable') == 0
  inventory = call(cli, 'library.inventory').fetch('result')
  checks['freshInventoryUsesActualModelAndPreservesEveryScannedFile'] = inventory['basis'] == 'app-current-model' &&
    inventory['checkPassed'] == true && inventory.dig('summary','files') == after.dig('libraryScan','entries')
  if require_posters
    checks['freshLibraryHasNoMissingPosters'] = inventory.dig('summary','missingPosters') == 0
  end
  before = call(cli, 'status').fetch('state')
  rejected = call(cli, 'navigate', {'section'=>'home','password'=>'OWNED-FIXTURE-NOT-A-CREDENTIAL'}, expected_ok: false)
  checks['unexpectedArgumentsFailClosed'] = rejected['error'] == 'invalid-section'
  checks['invalidCommandDoesNotChangeNavigation'] = call(cli, 'status').dig('state','section') == before['section']
  unknown = call(cli, 'unknown', {}, expected_ok: false)
  checks['unknownCommandsAreRejected'] = unknown['error'] == 'unknown-command'
  if initial['accountImportEnabled'] == false
    blocked = call(cli, 'account.importChrome', {'plugin'=>'mtv.quark'}, expected_ok: false)
    checks['accountImportRequiresSeparateExplicitEnablement'] = blocked['error'] == 'account-import-not-enabled'
    call(cli, 'account.open', {'plugin'=>'mtv.quark'})
    anonymous_challenge_requested = true
    wait_state(cli) { |s| s.dig('login','presented') && s.dig('login','state') != 'loading' }
    selection = nil
    6.times do
      selection = call(cli,'status').dig('state','login')
      target = selection.fetch('buttons').index('从Chrome导入')
      raise 'Expected Chrome import action is not present' unless target
      break if selection['selection'] == target
      call(cli,'input.key', {'key'=>selection['selection'] < target ? 'down' : 'up'})
    end
    blocked_key = call(cli,'input.key', {'key'=>'select'}, expected_ok: false)
    checks['genericNavigationCannotBypassChromeImportGate'] = blocked_key['error'] == 'account-import-not-enabled'
    after_block = call(cli,'status').dig('state','login')
    checks['blockedNavigationDoesNotBeginCookieReading'] = after_block['chromeImportDiagnostic'] == selection['chromeImportDiagnostic']
    call(cli,'account.close')
    checks['accountCloseUsesActualController'] = call(cli,'status').dig('state','login','presented') == false
  end
  events = call(cli, 'events', {'after'=>'0'}).fetch('result')
  encoded = JSON.generate(events)
  checks['eventsHaveSequenceAndBoundedPaging'] = events['events'].is_a?(Array) && events['events'].size <= 64 && events.key?('nextAfter') && events.key?('hasMore')
  checks['eventRecordsDoNotEchoRequestArguments'] = !encoded.include?('OWNED-FIXTURE-NOT-A-CREDENTIAL')
  call(cli, 'navigate', {'section'=>'home'})
  puts JSON.pretty_generate(schema: 1, scope: 'running-app-local-control', checks: checks,
    passed: checks.values.all?, physicalInputVerified: false, realChromeImportRequested: false,
    anonymousLoginChallengeMayBeRequested: anonymous_challenge_requested,
    mediaModified: false, originalLibraryCount: ready.dig('library','files'))
  exit(checks.values.all? ? 0 : 1)
rescue StandardError
  puts JSON.pretty_generate(schema: 1, scope: 'running-app-local-control', checks: checks, passed: false,
    error: 'Control acceptance failed; inspect the app structured state/events without publishing credentials')
  exit 1
end
