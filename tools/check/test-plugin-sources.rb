#!/usr/bin/env ruby
# Real Git transport and source UI integration against an owned local repository.
# This is not a private GitHub authentication test. Original packages/sources stay intact.
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'securerandom'
require 'uri'

CLI='/Applications/MacTV.app/Contents/MacOS/mtvctl'
def call(command,args={},failure:false)
  out,_err,status=Open3.capture3(CLI,'call',JSON.generate(command:command,arguments:args))
  result=JSON.parse(out)
  raise "Rejected #{command}: #{result['error']}" unless failure || (status.success? && result['ok'])
  result
end
def state; call('status')['state']; end
def ready
  deadline=Process.clock_gettime(Process::CLOCK_MONOTONIC)+30
  loop do
    s=state
    raise 'Installed fixture module failed to load' if s['section']=='bilibili' && s.dig('module','failed') && !s.dig('pluginManager','presented')
    return s unless s.dig('pluginManager','loading') || s.dig('module','loading')
    raise 'UI operation exceeded its deadline' if Process.clock_gettime(Process::CLOCK_MONOTONIC)>deadline
    sleep 0.1
  end
end
def ui(id)
  call('plugins.ui.activate',{'id'=>id}); ready
end
def close_manager
  10.times do
    s=state
    break unless s.dig('pluginManager','presented') || s.dig('input','visible')
    call('input.key',{'key'=>'escape'}); ready
  end
end
def open_sources
  call('settings.open',{'id'=>'plugins'}); ready; ui('sources')
end
def git(repo,*args)
  _out,_err,status=Open3.capture3('/usr/bin/git','-C',repo,'-c','core.hooksPath=/dev/null','-c','commit.gpgsign=false','-c','user.name=Source Fixture','-c','user.email=fixture@example.invalid',*args)
  raise 'Fixture Git failed' unless status.success?
end
def commit_package(repo,id,version,title)
  directory=File.join(repo,'plugin'); FileUtils.mkdir_p(directory)
  manifest={id:id,name:'Git Source Fixture',version:version,apiVersion:1,entry:'plugin.js',domains:[],capabilities:['browse']}
  File.write(File.join(directory,'manifest.json'),JSON.generate(manifest))
  File.write(File.join(directory,'plugin.js'),"const plugin={handle(action){if(action!=='browse')throw Error('unsupported');return {items:[{id:'fixture-item',title:#{JSON.generate(title)},source:'fixture',subtitle:'',overview:'',reference:'fixture-item'}]};}};")
  catalog={schemaVersion:2,id:'fixture',name:'Fixture',plugins:[{id:id,name:manifest[:name],version:version,apiVersion:1,directory:'plugin'}]}
  File.write(File.join(repo,'catalog.json'),JSON.generate(catalog))
  git(repo,'add','.'); git(repo,'commit','--quiet','-m',version)
end
before=state
abort 'Use an idle normal Home instance with --enable-control --allow-plugin-management' unless before['pluginManagementEnabled'] && !before['volatileHistory'] && before['section']=='home' && before['inputIdleSeconds'].to_f>=300 && before['overlays'].empty?
baseline_packages=call('plugins.list').dig('result','items')
baseline_sources=call('pluginSources.list').dig('result','items')
temporary=Dir.mktmpdir('mactv-git-source-')
repo=File.join(temporary,'repository'); FileUtils.mkdir_p(repo)
id='qa.git.'+SecureRandom.hex(6)
source_id=nil; checks={}
%w[INT TERM HUP].each { |signal| Signal.trap(signal) { raise Interrupt } }
begin
  git(repo,'init','--quiet','--initial-branch=main')
  commit_package(repo,id,'1.0.0','Version One')
  open_sources
  ui('source.add')
  checks['sourceUsesOnScreenTextInput']=state.dig('input','visible') && state.dig('input','target')=='pluginSourceURL'
  call('input.text',{'text'=>URI::Generic.build(scheme:'file',path:repo).to_s})
  call('input.submit'); ready
  source=call('pluginSources.list').dig('result','items').find { |entry| entry['url'].include?(repo) }
  raise 'Source was not added' unless source
  source_id=source['id']
  ui('source.open:'+source_id); ui('source.refresh')
  s=state
  checks['gitCatalogLoaded']=s.dig('pluginManager','catalogOrigin')=='git' && s.dig('pluginManager','catalogEntries').any? { |entry| entry['id']==id }
  first_revision=s.dig('pluginManager','catalogRevision')
  ui('source.install:'+id)
  checks['reviewRequiredBeforeInstall']=state.dig('pluginManager','reviewPlugin')==id && call('plugins.list').dig('result','items').none? { |entry| entry['id']==id }
  ui('approve')
  call('input.key',{'key'=>'backspace'}); ready
  checks['backReturnsToSourceList']=state.dig('pluginManager','sourceMode') && state.dig('pluginManager','sourceID')==''
  close_manager
  call('module.open',{'plugin'=>id}); ready
  checks['downloadedCodeExecutes']=call('module.list').dig('result','items',0,'title')=='Version One'
  installed=call('plugins.list').dig('result','items').find { |entry| entry['id']==id }
  checks['installedCommitRecorded']=installed['origin']=='git' && installed['revision']==first_revision
  commit_package(repo,id,'1.1.0','Version Two')
  open_sources; ui('source.open:'+source_id); ui('source.refresh')
  checks['fetchSeesNewCommit']=state.dig('pluginManager','catalogRevision') != first_revision
  ui('source.install:'+id); ui('approve'); close_manager
  call('module.open',{'plugin'=>id}); ready
  checks['updatedCodeExecutesWithoutRestart']=call('module.list').dig('result','items',0,'title')=='Version Two' && state['pid']==before['pid']
  call('pluginSources.enable',{'id'=>source_id,'enabled'=>'false'})
  blocked=call('pluginSources.catalog',{'id'=>source_id},failure:true)
  checks['disabledSourceCannotRefresh']=!blocked['ok']
  call('pluginSources.enable',{'id'=>source_id,'enabled'=>'true'})
  review=call('pluginSources.review',{'id'=>source_id,'plugin'=>id}).dig('result','review')
  call('pluginSources.remove',{'id'=>source_id})
  rejected=call('plugins.approve',{'review'=>review},failure:true)
  checks['removedSourceInvalidatesPendingReview']=!rejected['ok']
  checks['removingSourceKeepsInstalledPlugin']=call('plugins.list').dig('result','items').any? { |entry| entry['id']==id && entry['enabled'] }
  call('module.open',{'plugin'=>id}); ready
  checks['installedPluginDoesNotDependOnSourceAvailability']=call('module.list').dig('result','items',0,'title')=='Version Two'
ensure
  close_manager rescue nil
  call('plugins.remove',{'id'=>id},failure:true) rescue nil
  call('pluginSources.remove',{'id'=>source_id},failure:true) rescue nil if source_id
  call('navigate',{'section'=>'home'}) rescue nil
  FileUtils.remove_entry(temporary)
end
checks['userPackagesPreserved']=call('plugins.list').dig('result','items')==baseline_packages
checks['userSourcesPreserved']=call('pluginSources.list').dig('result','items')==baseline_sources
report={kind:'git-plugin-source-ui',checks:checks,passed:checks.values.all?,privateGitHubAuthenticationVerified:false,pid:state['pid']}
puts JSON.pretty_generate(report)
directory=File.expand_path('~/Library/Application Support/MTV/TestResults')
FileUtils.mkdir_p(directory,mode:0700)
File.write(File.join(directory,'git-plugin-sources.json'),JSON.pretty_generate(report))
exit(report[:passed] ? 0:1)
