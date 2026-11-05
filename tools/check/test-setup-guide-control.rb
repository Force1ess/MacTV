#!/usr/bin/env ruby
require 'json'
require 'open3'
cli = '/Applications/MacTV.app/Contents/MacOS/mtvctl'
def call(cli, operation, arguments = {})
  data, _error, status = Open3.capture3(cli,'call',JSON.generate(command:operation,arguments:arguments))
  result = JSON.parse(data)
  raise 'Guide control failed' unless status.success? && result['ok']
  result.fetch('state')
end
checks = {}
observed_devices = nil
begin
  initial = call(cli,'status')
  raise 'Stop playback and close overlays first' if initial.dig('playback','presented') || !initial.fetch('overlays').empty?
  state = call(cli,'settings.open',{'id'=>'about'})
  4.times do |step|
    guide = state.fetch('guide')
    checks["step#{step}HasTextAndActions"] = guide['step'] == step && !guide['description'].empty? && !guide['actions'].empty?
    if step == 1
      checks['diskAccessIsScopedToChromeAndRequiresRelaunch'] = ['Chrome','重新打开','普通影片播放和扫码登录不需要'].all?{|term|guide['description'].include?(term)}
      checks['primaryActionUsesExactSystemPermissionName'] = guide.fetch('actions').first['title'] == '打开完全磁盘访问权限'
      checks['guideGivesExactSystemSettingsPath'] = guide['description'].include?('系统设置 → 隐私与安全性 → 完全磁盘访问权限')
    elsif step == 2
      checks['chromeImportExplainsFirstAuthorizationAndAlwaysAllow'] = ['Chrome','钥匙串密码','始终允许'].all?{|term|guide['description'].include?(term)}
      checks['loginStepHasOnlyTwoPlatformActions'] = guide['actions'].map{|a|a['title']} == ['登录哔哩哔哩','登录夸克网盘']
      checks['bothPlatformsExplainTheirOwnChromeImport'] = guide['actions'].all?{|a|a['description'].include?('Chrome')}
    elsif step == 3
      checks['recommendsRemoteOrTrackpad'] = guide['description'].include?('推荐使用遥控器或触控板')
      mapping = guide.fetch('keymap').find{|binding|binding['action']=='返回上一级'}
      checks['returnKeymapIsVisibleWithoutAnotherDialog'] = mapping && mapping['keys'] == 'Esc / Backspace'
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      while !guide['inputDevices'] && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.1
        state = call(cli,'status'); guide = state.fetch('guide')
      end
      checks['inputDevicePresenceHasTextEvidence'] = ['available','unavailable'].include?(guide.dig('inputDevices','status')) && guide.dig('inputDevices','devices').is_a?(Array)
      observed_devices = guide['inputDevices']
    end
    10.times do
      break if state.dig('guide','selection') == state.dig('guide','nextIndex')
      state = call(cli,'input.key',{'key'=>'down'})
    end
    raise 'Guide next action not reachable' unless state.dig('guide','selection') == state.dig('guide','nextIndex')
    state = call(cli,'input.key',{'key'=>'select'})
  end
  checks['guideCompletesThroughSameNavigationHandler'] = !state.fetch('overlays').include?('setupGuide')
  call(cli,'navigate',{'section'=>'home'})
  puts JSON.pretty_generate(scope:'setup-guide-text-interface',checks:checks,passed:checks.values.all?,inputDevices:observed_devices,imagesUsed:false,systemPermissionsChanged:false)
  exit(checks.values.all? ? 0 : 1)
rescue StandardError
  puts JSON.pretty_generate(scope:'setup-guide-text-interface',checks:checks,passed:false,error:'Guide verification failed; inspect text state')
  exit 1
end
