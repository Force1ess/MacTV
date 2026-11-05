#!/usr/bin/env ruby
# Explicit own-account real playback. No browser reads, credential logging,
# external player, system input synthesis or permission edits. Optional layout
# export captures only MTV's own content view through its separately gated API.
require 'json'
require 'open3'
options = ARGV.dup
grant = options.delete('--grant-approved-scope')
verify_revoke = options.delete('--verify-revoke')
export_controls = options.delete('--export-controls-layout')
verify_subtitles = options.delete('--verify-embedded-subtitles')
export_subtitle_frame = options.delete('--export-subtitle-frame')
visual = nil
file_id = options.pop
folders = options
abort 'Usage: test-quark-native-playback.rb [--grant-approved-scope] [--verify-revoke] [--export-controls-layout] [FOLDER_ID ...] FILE_ID' unless file_id && (folders+[file_id]).all?{|id|id.match?(/\A[A-Za-z0-9_-]{1,128}\z/)}
CLI = '/Applications/MacTV.app/Contents/MacOS/mtvctl'
RUN = {}
checks = {}
metrics = {}
def call(command, arguments = {})
  output, _stderr, status = Open3.capture3(CLI,'call',JSON.generate(command:command,arguments:arguments))
  result = JSON.parse(output)
  raise 'Control failed' unless status.success? && result['ok']
  if RUN['pid'] && (result.dig('state','pid') != RUN['pid'] || result.dig('state','controlRunID') != RUN['id'])
    raise 'App instance changed during playback verification'
  end
  result
end
def wait_state(timeout=40)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    state = call('status').fetch('state')
    return state if yield(state)
    raise 'Expected native state did not arrive' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.1
  end
end
def activate(id)
  items=call('module.list',{'limit'=>'100'}).dig('result','items')
  raise 'Explicit target is not on current module page' unless items.any?{|item|item['id']==id}
  call('item.activate',{'id'=>id})
end
begin
  startup_deadline=Process.clock_gettime(Process::CLOCK_MONOTONIC)+15
  loop do
    begin
      call('status'); break
    rescue StandardError
      raise if Process.clock_gettime(Process::CLOCK_MONOTONIC)>=startup_deadline
      sleep 0.1
    end
  end
  before=call('status').fetch('state')
  expected=ENV['MTV_EXPECTED_PID']
  raise 'Unexpected app instance' if expected && before['pid'] != Integer(expected)
  RUN['pid']=before['pid']; RUN['id']=before['controlRunID']
  raise 'Stop existing playback or overlays before test' if before.dig('playback','presented') || !before['overlays'].empty?
  if verify_revoke
    raise 'Revocation/reapproval test requires explicit grant option' unless grant
    call('account.revokeMediaSession',{'plugin'=>'mtv.quark'})
    revoked=call('status').fetch('state')
    checks['explicitRevokeClearsCurrentApproval']=revoked['approvedQuarkMediaSessionEnabled']==false
    checks['explicitRevokeStopsAnyNativePlayback']=!revoked.dig('playback','presented')
  end
  # No diagnostic startup override: verify the ordinary first-use consent path.
  checks['ownQuarkAccountIsConfigured'] = before.fetch('accounts').any?{|a|a['plugin']=='mtv.quark'&&a['configured']}
  call('module.open',{'plugin'=>'mtv.quark'})
  wait_state{|s|!s.dig('module','loading')}
  folders.each do |folder|
    activate(folder)
    wait_state{|s|!s.dig('module','loading')}
  end
  clicked_at=Process.clock_gettime(Process::CLOCK_MONOTONIC)
  activate(file_id)
  ready=wait_state{|s|s['mediaSessionConsent'] || s.dig('playback','presented') || s['notice']}
  consent_tested=false
  if ready['mediaSessionConsent']
    pending=ready.fetch('mediaSessionConsent')
    checks['firstUseShowsExactNativeMediaScope'] = pending['host']=='video-play-c-sz.drive.quark.cn' && pending['plugin']=='mtv.quark'
    checks['firstUseDefaultsToDecline'] = pending['selection']==1
    call('input.key',{'key'=>'escape'})
    cancelled=call('status').fetch('state')
    checks['backCancelsWithoutGrantingOrPlaying'] = !cancelled['mediaSessionConsent'] && !cancelled['approvedQuarkMediaSessionEnabled'] && !cancelled.dig('playback','presented')
    raise 'Actual media consent needs explicit operator approval' unless grant
    activate(file_id)
    wait_state{|s|s['mediaSessionConsent']}
    call('input.key',{'key'=>'up'})
    call('input.key',{'key'=>'select'})
    consent_tested=true
  end
  playing=wait_state(45){|s|s['notice'] || (s.dig('playback','nativeElapsed').to_f>2 && s.dig('playback','videoWidth').to_i>0 && s.dig('playback','nativeSeeking')!=true && s.dig('playback','nativeBuffering')!=true && (s.dig('playback','timeControlStatus')==2 || (s.dig('playback','engine')=='mpv' && s.dig('playback','nativePaused')==false)))}
  raise 'Actual source failed to start' if playing['notice']
  metrics['clickToNativeClockAndVideoMs']=((Process.clock_gettime(Process::CLOCK_MONOTONIC)-clicked_at)*1000).round(1)
  player=playing.fetch('playback')
  checks['actualRequestedFileIsPlaying'] = player.dig('item','id')==file_id && %w[system mpv].include?(player['engine'])
  checks['nativeTimeAndVideoDimensionsAreValid'] = player['nativeElapsed']>2 && player['nativeDuration']>30 && player['videoHeight']>0 && player['videoWidth']>0
  call('playback.toggle')
  paused=wait_state{|s|s.dig('playback','paused')}
  pause_time=paused.dig('playback','nativeElapsed')
  sleep 0.5
  stationary=call('status').fetch('state')
  checks['pauseStopsNativeClock']=(stationary.dig('playback','nativeElapsed')-pause_time).abs<0.25
  if export_controls
    visual = call('visual.export',{'purpose'=>'layout'}).fetch('result')
    checks['controlsLayoutExportContainsOnlyMTVContent'] = visual['scope']=='MTV-content-view-only'
  end
  call('playback.seek',{'seconds'=>'12'})
  seeked=wait_state{|s|(s.dig('playback','nativeElapsed').to_f-12).abs<0.3 && s.dig('playback','nativeSeeking')!=true}
  checks['seekUsesNativeClockAndKeepsPause']=seeked.dig('playback','paused')==true
  call('playback.rate',{'rate'=>'1.5'})
  call('playback.toggle')
  resumed=wait_state{|s|(s.dig('playback','timeControlStatus')==2 || (s.dig('playback','engine')=='mpv'&&s.dig('playback','nativePaused')==false))&&s.dig('playback','nativeElapsed').to_f>13}
  checks['resumeKeepsSelectedSpeed']=resumed.dig('playback','rate')==1.5
  checks['noNativeInterruptionNotice']=resumed['notice'].nil?
  if verify_subtitles || export_subtitle_frame
    call('playback.tracks',{'kind'=>'subtitles'})
    menu=wait_state{|s|s.dig('playback','tracks','presented')&&!s.dig('playback','tracks','loading')}.dig('playback','tracks')
    embedded=menu.fetch('options').select{|option|!option['external']&&option['trackID'].to_i>0}
    checks['originalStreamExposesEmbeddedSubtitleTracks']=!embedded.empty?
    raise 'No embedded tracks in actual source' if embedded.empty?
    selected=embedded.find{|option|option['title'].match?(/Chs|简体/i)}||embedded.find{|option|option['title'].match?(/chi|zho|zh|简|繁/i)}||embedded.first
    call('playback.selectTrack',{'requestID'=>menu['requestID'],'index'=>selected['index'].to_s})
    wait_state{|s|!s.dig('playback','tracks','presented')}
    call('playback.tracks',{'kind'=>'subtitles'})
    actual=wait_state{|s|s.dig('playback','tracks','presented')&&!s.dig('playback','tracks','loading')}.dig('playback','tracks')
    checks['embeddedSubtitleSelectionReachesActualBackend']=actual['selectedID']==selected['trackID']
    off=actual.fetch('options').find{|option|option['trackID']==-1}
    call('playback.selectTrack',{'requestID'=>actual['requestID'],'index'=>off.fetch('index').to_s})
    wait_state{|s|!s.dig('playback','tracks','presented')}
    call('playback.tracks',{'kind'=>'subtitles'})
    disabled=wait_state{|s|s.dig('playback','tracks','presented')&&!s.dig('playback','tracks','loading')}.dig('playback','tracks')
    checks['embeddedSubtitlesCanBeDisabled']=disabled['selectedID']==-1
    call('input.key',{'key'=>'escape'})
    if export_subtitle_frame
      call('playback.tracks',{'kind'=>'subtitles'})
      available=wait_state{|s|s.dig('playback','tracks','presented')&&!s.dig('playback','tracks','loading')}.dig('playback','tracks')
      candidate=available.fetch('options').find{|option|option['trackID']==selected['trackID']}
      call('playback.selectTrack',{'requestID'=>available['requestID'],'index'=>candidate.fetch('index').to_s})
      wait_state{|s|!s.dig('playback','tracks','presented')}
      call('playback.toggle') unless call('status').dig('state','playback','paused')
      wait_state{|s|s.dig('playback','paused')}
      call('playback.seek',{'seconds'=>'240'})
      wait_state{|s|(s.dig('playback','nativeElapsed').to_f-240).abs<0.3 && s.dig('playback','nativeSeeking')!=true}
      call('playback.toggle')
      wait_state{|s|s.dig('playback','nativeElapsed').to_f>245 && s.dig('playback','nativeBuffering')!=true}
      call('playback.toggle')
      wait_state{|s|s.dig('playback','nativePaused')==true}
      sleep 0.5
      visual=call('visual.export',{'purpose'=>'subtitles'}).fetch('result')
      checks['subtitleVerificationUsesOnlyNativePlayerFrame']=visual['scope']=='native-player-frame-only'
    end
  end
  call('playback.stop')
  stopped=call('status').fetch('state')
  checks['stopReleasesActualPlayback']=!stopped.dig('playback','presented')&&!stopped.dig('playback','preparing')
  call('navigate',{'section'=>'home'})
  puts JSON.pretty_generate(schema:1,scope:'real-quark-native-playback',checks:checks,passed:checks.values.all?,
    firstUseConsentTested:consent_tested,pid:playing['pid'],videoHeight:player['videoHeight'],videoWidth:player['videoWidth'],
    duration:player['nativeDuration'],metrics:metrics,imagesUsed:false,visualExport:visual,physicalAudioVerified:false,volatileHistory:before['volatileHistory']==true,credentialsPrinted:false)
  exit(checks.values.all? ? 0 : 1)
rescue StandardError
  puts JSON.pretty_generate(schema:1,scope:'real-quark-native-playback',checks:checks,passed:false,
    error:'Native playback test did not complete; inspect current structured state without publishing signed URLs',credentialsPrinted:false)
  exit 1
end
