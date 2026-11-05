#!/usr/bin/env ruby
# Exercise the real running app using disposable copies of the two examples.
# Never removes or replaces the user's actual Gallery/Steam installations.
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'securerandom'

ROOT = File.expand_path('../..',__dir__)
CLI = '/Applications/MacTV.app/Contents/MacOS/mtvctl'
checks = {}
class ControlNotReady < StandardError; end
def call(command, arguments = {}, allow_failure: false)
  out, _err, status = Open3.capture3(CLI,'call',JSON.generate(command:command,arguments:arguments))
  value = JSON.parse(out.empty? ? _err : out)
  if !status.success? && %w[control-not-running-or-unsafe control-connection-rejected].include?(value["error"])
    raise ControlNotReady, "App control is still starting"
  end
  raise "Control rejected #{command}: #{value['error']}" unless allow_failure || (status.success? && value['ok'])
  value
end
def listed
  call('plugins.list').dig('result','items')
end
def browse(id)
  call('module.open',{'plugin'=>id})
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC)+20
  loop do
    state = call('status')['state']
    raise 'Gallery page failed' if state.dig('module','failed')
    break unless state.dig('module','loading')
    raise 'Gallery page deadline exceeded' if Process.clock_gettime(Process::CLOCK_MONOTONIC)>deadline
    sleep 0.1
  end
  call('module.list').dig('result','items')
end
def install(directory)
  review = call('plugins.review',{'directory'=>directory})['result']
  expected = JSON.parse(File.read(File.join(directory,'manifest.json')))
  raise 'Review does not match the package' unless review['manifest']==expected
  call('plugins.approve',{'review'=>review['review']})
end
# Installation launches asynchronously. Await only initial read readiness;
# never retry a plugin mutation or bypass the idle/user-activity checks.
readiness_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
begin
  before = call('status')['state']
rescue ControlNotReady
  raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= readiness_deadline
  sleep 0.1
  retry
end
abort 'Start an idle normal app on Home with --enable-control --allow-plugin-management' unless before['pluginManagementEnabled'] && !before['volatileHistory'] && before['section']=='home' && before['inputIdleSeconds'].to_f>=300 && before['overlays'].empty? && !before.dig('playback','presented')
pid = before['pid']
baseline = listed
prefix = 'qa.examples.'+SecureRandom.hex(6)
ids = %w[gallery steam].map { |name| prefix+'.'+name }
temporary = Dir.mktmpdir('mactv-plugin-lifecycle-')
%w[INT TERM HUP].each { |signal| Signal.trap(signal) { raise Interrupt } }
begin
  rejected = call('plugins.approve',{'review'=>SecureRandom.uuid},allow_failure:true)
  checks['unreviewedCodeRejected'] = !rejected['ok'] && listed==baseline
  %w[gallery steam].each_with_index do |name,index|
    source = File.join(ROOT,'examples',name,'dist')
    directory = File.join(temporary,name)
    FileUtils.cp_r(source,directory)
    manifest_path = File.join(directory,'manifest.json')
    manifest = JSON.parse(File.read(manifest_path)); manifest['id'] = ids[index]
    File.write(manifest_path,JSON.pretty_generate(manifest))
    install(directory)
    checks[name+'InstalledLive'] = listed.any? { |p| p['id']==ids[index] && p['enabled'] }
    if name=='gallery'
      items = browse(ids[index])
      checks['galleryCodeRunsWithAnotherPluginIdentity'] = !items.empty? && items.all? { |item| item['source']==ids[index] }
      manifest['version'] = '0.3.1-qa'; File.write(manifest_path,JSON.pretty_generate(manifest))
      File.open(File.join(directory,'plugin.js'),'a') do |file|
        async=manifest['apiVersion']==2 ? 'async ' : ''
        await=manifest['apiVersion']==2 ? 'await ' : ''
        file.write("\nconst priorExample=plugin; plugin={#{async}handle(action,input){const page=#{await}priorExample.handle(action,input);return {...page,items:page.items.map(item=>({...item,title:item.title+' [updated example]'}))};}};\n")
      end
      install(directory)
      updated = browse(ids[index])
      checks['hotUpdateExecutesNewCode'] = !updated.empty? && updated.all? { |item| item['title'].end_with?(' [updated example]') }
    end
    call('plugins.enable',{'id'=>ids[index],'enabled'=>'false'})
    checks[name+'DisabledLive'] = listed.any? { |p| p['id']==ids[index] && !p['enabled'] } && !call('module.open',{'plugin'=>ids[index]},allow_failure:true)['ok']
    call('plugins.enable',{'id'=>ids[index],'enabled'=>'true'})
    checks[name+'EnabledLive'] = listed.any? { |p| p['id']==ids[index] && p['enabled'] }
    call('plugins.remove',{'id'=>ids[index]})
    checks[name+'RemovedLive'] = listed.none? { |p| p['id']==ids[index] }
  end
  checks['userPackagesPreserved'] = listed==baseline
  checks['sameApplicationProcess'] = call('status').dig('state','pid')==pid
ensure
  ids.each { |id| call('plugins.remove',{'id'=>id},allow_failure:true) rescue nil }
  call('navigate',{'section'=>'home'}) rescue nil
  FileUtils.remove_entry(temporary)
end
report = {kind:'example-plugin-lifecycle',checks:checks,passed:checks.values.all?,pid:pid,physicalSteamReturnVerified:false}
puts JSON.pretty_generate(report)
directory = File.expand_path('~/Library/Application Support/MTV/TestResults')
FileUtils.mkdir_p(directory,mode:0700)
File.write(File.join(directory,'example-plugin-lifecycle.json'),JSON.pretty_generate(report))
exit(report[:passed] ? 0:1)
