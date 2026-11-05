#!/usr/bin/env ruby
require 'json'
require 'open3'
require 'fileutils'
require 'securerandom'
require 'base64'
require 'socket'
require 'timeout'

root = File.expand_path('../..', __dir__)
app = ARGV.first || File.join(root, 'dist/MacTV.app')
helper = File.join(app, 'Contents/Helpers/MTVPluginHost.app/Contents/MacOS/MTVPluginHost')
control = File.join(root, '.build/release/MTVPluginHost')
output = File.join(root, '.build', 'BrokerHostRun-' + SecureRandom.uuid)
FileUtils.mkdir_p(output)
read_path = File.join(output, 'generated-canary.txt'); File.write(read_path, 'TEST_ONLY')
server = TCPServer.new('127.0.0.1', 0)
checks = {}; observations = {}
[['control', control], ['sandbox', helper]].each do |name, executable|
  input = {read:read_path,write:File.join(output, name + '-generated.txt'),port:server.addr[1].to_s}
  stdout, stderr, status = Timeout.timeout(20) { Open3.capture3(executable, '--isolation-probe', stdin_data:JSON.generate(input)) }
  File.write(File.join(output, name + '.json'), stdout); File.write(File.join(output, name + '.stderr'), stderr)
  observations[name] = JSON.parse(stdout) if status.success?
end
c, s = observations.values_at('control','sandbox')
checks['controlHasFileAndLoopbackAccess'] = c && c['readAllowed'] && c['writeAllowed'] && c['networkAllowed']
checks['scriptHostCannotAccessOutsideFiles'] = s && s['readAllowed'] == false && s['writeAllowed'] == false
checks['scriptHostHasNoDirectNetwork'] = s && s['networkAllowed'] == false && s['networkErrno'] == 1
checks['spawnedCommandStillCannotWriteOutside'] = s && s['childStatus'] != 0
server.close

def write_frame(io, object)
  data = JSON.generate(object); io.write([data.bytesize].pack('N')); io.write(data); io.flush
end
def read_frame(io)
  header = io.read(4); raise 'missing frame' unless header && header.bytesize == 4
  count = header.unpack1('N'); raise 'oversize frame' if count <= 0 || count > 3_000_000
  data = io.read(count); raise 'truncated frame' unless data && data.bytesize == count
  JSON.parse(data)
end
manifest = {id:'dev.broker.probe',name:'Own fixture',version:'1',apiVersion:1,entry:'plugin.js',domains:[],capabilities:['browse']}
code = 'const plugin={handle(){const r=host.fetchJSON("https://not-approved.invalid/test");return {items:[],echo:r.value,sessionAvailable:host.sessionAvailable,keys:Object.keys(__request)}}};'
bootstrap = {action:'browse',input:{safe:'value'},approvedManifest:manifest,scriptBase64:Base64.strict_encode64(code),sessionAvailable:true}
legacy_stdout, _legacy_stderr, legacy_status = Timeout.timeout(20) { Open3.capture3(helper,'--payload',stdin_data:JSON.generate(bootstrap)) }
checks['sandboxHelperCannotReenableLegacyNetworkMode'] = !legacy_status.success? && JSON.parse(legacy_stdout).fetch('error').include?('只接受')
Timeout.timeout(20) do
  Open3.popen3(helper,'--brokered') do |stdin, stdout, stderr, thread|
    write_frame(stdin, bootstrap)
    request = read_frame(stdout)
    checks['scriptUsesOnlyFramedFetchChannel'] = request['type'] == 'fetch' && request['id'] == 1 && request['url'] == 'https://not-approved.invalid/test'
    # Transport fixture only. The real native policy is separately tested; no network occurs here.
    response = JSON.generate(status:200,body:JSON.generate(value:'PARENT_FIXTURE_ONLY'))
    write_frame(stdin,{type:'reply',id:1,payload:Base64.strict_encode64(response)})
    result = read_frame(stdout); stdin.close
    checks['scriptReceivesReplyWithoutPrivateBootstrap'] = result.dig('result','echo') == 'PARENT_FIXTURE_ONLY' && result.dig('result','sessionAvailable') == true && result.dig('result','keys').sort == ['action','input']
    checks['brokeredScriptExitsNormally'] = thread.value.success?
    File.write(File.join(output,'brokered-result.json'), JSON.pretty_generate(result))
    File.write(File.join(output,'brokered.stderr'), stderr.read)
  end
end
Timeout.timeout(20) do
  Open3.popen3(helper,'--brokered') do |stdin, stdout, _stderr, thread|
    write_frame(stdin,bootstrap.merge(credential:{cookie:'TEST_ONLY_MUST_NOT_ENTER_WORKER'}))
    frame = read_frame(stdout); stdin.close
    checks['privateCredentialInWorkerBootstrapIsRejected'] = frame['type'] == 'error' && frame['error'].include?('私有会话') && !thread.value.success?
  end
end
Timeout.timeout(20) do
  Open3.popen3(helper,'--brokered') do |stdin, stdout, _stderr, thread|
    write_frame(stdin,bootstrap); request = read_frame(stdout)
    write_frame(stdin,{type:'reply',id:request['id']+1,payload:Base64.strict_encode64('{}')})
    frame = read_frame(stdout); stdin.close
    checks['wrongReplySequenceCannotBecomeData'] = frame['type'] == 'error' && !thread.value.success?
  end
end
[
  [:approvedManifest, 'brokeredPayloadWithoutApprovedManifestIsRejected', '缺少已审核清单'],
  [:scriptBase64, 'brokeredPayloadWithoutCodeIsRejected', '缺少有效脚本']
].each do |missing, label, reason|
  Timeout.timeout(20) do
    Open3.popen3(helper, '--brokered') do |stdin, stdout, _stderr, thread|
      write_frame(stdin, bootstrap.reject { |key, _| key == missing })
      frame = read_frame(stdout); stdin.close
      checks[label] = frame['type'] == 'error' && frame['error'].include?(reason) && !thread.value.success?
    end
  end
end
report = {passed:checks.values.all? { |v| v == true },checks:checks,observations:observations,output:output,transportFixtureOnly:true}
File.write(File.join(output,'report.json'), JSON.pretty_generate(report)); puts JSON.pretty_generate(report)
exit(report[:passed] ? 0 : 1)
