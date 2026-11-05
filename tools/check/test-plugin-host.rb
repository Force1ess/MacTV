#!/usr/bin/env ruby
require 'json'
require 'open3'
require 'timeout'

root = File.expand_path('../..', __dir__)
host = ARGV.first || File.join(root, '.build/debug/MTVPluginHost')
checks = {}
request = JSON.generate(action: 'browse', input: {})
stdout, _stderr, status = Open3.capture3(host, File.join(root, 'src/Tests/Fixtures/example-plugin'), stdin_data: request)
checks['exampleReturnsPage'] = status.success? && JSON.parse(stdout).dig('result', 'items', 0, 'id') == 'hello'
stdout, _stderr, status = Open3.capture3(host, File.join(root, 'src/Tests/Fixtures/network-denied'), stdin_data: request)
checks['networkDenied'] = !status.success? && JSON.parse(stdout).fetch('error').include?('拒绝请求')

credential = {pluginID: 'test.session', domains: ['api.example.test'], cookie: 'sid=TEST_ONLY', savedAt: Time.now.to_f}
private_request = {action: 'browse', input: {}, credential: credential}
stdout, _stderr, status = Open3.capture3(host, File.join(root, 'src/Tests/Fixtures/private-session'), stdin_data: JSON.generate(private_request))
value = JSON.parse(stdout).fetch('result', {})
checks['sessionNotExposedToJavaScript'] = status.success? && value['leaked'] == false && value['cookieReadable'] == false && value['sessionAvailable'] == true && value['requestKeys'] == ['action', 'input']
['denied-origin', 'denied-login-path', 'denied-post', 'denied-method'].each do |mode|
  private_request[:input] = {mode: mode}
  stdout, _stderr, status = Open3.capture3(host, File.join(root, 'src/Tests/Fixtures/private-session'), stdin_data: JSON.generate(private_request))
  checks[mode] = !status.success? && !!JSON.parse(stdout)['error']
end
private_request[:credential] = credential.merge(pluginID: 'another.module')
private_request[:input] = {}
stdout, _stderr, status = Open3.capture3(host, File.join(root, 'src/Tests/Fixtures/private-session'), stdin_data: JSON.generate(private_request))
checks['crossPluginCredentialRejected'] = !status.success? && !!JSON.parse(stdout)['error']

previous_term = Signal.trap('TERM', 'IGNORE')
begin
  Open3.popen3(host, File.join(root, 'src/Tests/Fixtures/infinite-loop')) do |stdin, stdout_pipe, stderr_pipe, process|
    stdin.write(request); stdin.close
    sleep 1
    begin
      Process.kill('TERM', process.pid)
      Timeout.timeout(3) { process.join }
      checks['workerResetsInheritedIgnoredSIGTERM'] = process.value.signaled? && process.value.termsig == Signal.list['TERM']
    rescue Timeout::Error
      Process.kill('KILL', process.pid); process.join
      checks['workerResetsInheritedIgnoredSIGTERM'] = false
    rescue Errno::ESRCH
      checks['workerResetsInheritedIgnoredSIGTERM'] = false
    ensure
      stdout_pipe.close; stderr_pipe.close
    end
  end
ensure
  Signal.trap('TERM', previous_term)
end

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
Open3.popen3(host, File.join(root, 'src/Tests/Fixtures/infinite-loop')) do |stdin, stdout_pipe, stderr_pipe, process|
  stdin.write(request); stdin.close
  begin
    Timeout.timeout(15) { process.join }
    checks['infiniteLoopTerminated'] = process.value.signaled?
  rescue Timeout::Error
    Process.kill('KILL', process.pid)
    process.join
    checks['infiniteLoopTerminated'] = false
  ensure
    stdout_pipe.close; stderr_pipe.close
  end
end
puts JSON.pretty_generate(checks: checks, passed: checks.values.all?, elapsed: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2))
exit(checks.values.all? ? 0 : 1)
