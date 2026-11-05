#!/usr/bin/env ruby
# Real window handoff/return, using the current plugin's declared selector.
# The application may exit itself when its last window closes; MacTV never kills it.
require 'json'
require 'open3'
require 'fileutils'
CLI='/Applications/MacTV.app/Contents/MacOS/mtvctl'
def call(command,args={})
  out,_err,status=Open3.capture3(CLI,'call',JSON.generate(command:command,arguments:args))
  value=JSON.parse(out)
  raise "Rejected #{command}: #{value['error']}" unless status.success? && value['ok']
  value
end
def await_phase(expected,seconds)
  deadline=Process.clock_gettime(Process::CLOCK_MONOTONIC)+seconds
  loop do
    result=call('application.status')['result']
    return result if result['phase']==expected
    raise "Launcher phase #{result['phase']}; expected #{expected}" if %w[needs-accessibility not-installed launch-failed window-not-observed observation-unavailable].include?(result['phase']) || Process.clock_gettime(Process::CLOCK_MONOTONIC)>deadline
    sleep 0.25
  end
end
initial=call('status')['state']
abort 'Use idle Home with explicit developer plugin management enabled' unless initial['pluginManagementEnabled'] && initial['section']=='home' && initial['inputIdleSeconds'].to_f>=300 && initial['overlays'].empty?
checks={}
begin
  call('module.open',{'plugin'=>'community.steam'})
  active=await_phase('active',30)
  checks['declaredSteamWindowObserved']=active['observedWindowID'].to_i>0
  deadline=Process.clock_gettime(Process::CLOCK_MONOTONIC)+8
  loop do
    inspection=call('application.inspect')['result']
    checks['actualFullscreenObserved']=inspection.fetch('windows',[]).any? { |w| w['title']=='Steam Big Picture Mode' && w['fullscreen'] }
    break if checks['actualFullscreenObserved'] || Process.clock_gettime(Process::CLOCK_MONOTONIC)>deadline
    sleep 0.25
  end
  checks['scopedWindowCloseAccepted']=call('application.closeObservedWindow')['accepted']
  returned=await_phase('returned',15)
  current=call('status')['state']
  checks['returnedToMacTV']=current['active'] && current['keyWindow'] && current['section']=='home'
  checks['sameApplicationProcess']=current['pid']==initial['pid']
  report={kind:'steam-window-return',checks:checks,passed:checks.values.all?,applicationStillRunning:returned['familyProcesses'].to_i>0,physicalRemoteVerified:false}
  puts JSON.pretty_generate(report)
  directory=File.expand_path('~/Library/Application Support/MTV/TestResults')
  FileUtils.mkdir_p(directory,mode:0700)
  File.write(File.join(directory,'steam-window-return.json'),JSON.pretty_generate(report))
ensure
  call('navigate',{'section'=>'home'}) rescue nil
  call('window.show') rescue nil
end
exit(report[:passed] ? 0:1)
