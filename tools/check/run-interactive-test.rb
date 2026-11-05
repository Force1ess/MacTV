#!/usr/bin/env ruby
# The only supported in-place UI test entrypoint. Never leaves the installed
# application in test mode, including when this supervisor is interrupted.
require 'json'
require 'open3'
require 'net/http'
ROOT = File.expand_path('../..',__dir__)
CLI = '/Applications/MacTV.app/Contents/MacOS/mtvctl'
arguments = ARGV.dup
fixture_file = nil
if (index = arguments.index('--owned-http-fixture'))
  abort 'Owned HTTP fixture requires its generated media path' unless index + 1 < arguments.length
  fixture_file = File.expand_path(arguments[index + 1])
  arguments.slice!(index,2)
  expected = File.expand_path('~/Library/Application Support/MTV/Fixtures') + '/'
  abort 'Use a regular generated fixture inside MTV/Fixtures' unless File.file?(fixture_file) && !File.symlink?(fixture_file) && File.realpath(fixture_file).start_with?(expected)
  abort 'HTTP fixture scope is required' unless arguments.any? { |value| %w[--remote-header-only --indexed-range-only].include?(value) }
  abort 'The owned fixture assigns its own port' if arguments.include?('--test-http-port')
end
abort 'Supply an explicit --ui-smoke test scope' unless arguments.include?('--ui-smoke')
abort 'Supervisor identity is assigned by this runner' if arguments.include?('--supervised-ui-test')
def state
  out, _err, status = Open3.capture3(CLI,'status')
  value = JSON.parse(out)
  status.success? && value['ok'] ? value['state'] : nil
rescue JSON::ParserError
  nil
end
before = state
# The installer launches asynchronously. Wait for the normal app to publish its
# first control snapshot; never relaunch it or bypass the user-activity guard.
startup_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
while before.nil? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < startup_deadline
  sleep 0.2
  before = state
end
abort 'Start normal MacTV with --enable-control first' unless before && before['phase']=='running' && !before['volatileHistory']
abort 'MacTV is not foreground; test not started' unless before['active']
abort 'MacTV is being used; test not started' if before['inputIdleSeconds'].to_f < 300 || before.dig('playback','presented') || !before.fetch('overlays').empty?
%w[INT TERM HUP].each { |signal| Signal.trap(signal) { raise Interrupt } }
test_pid = nil
fixture_pid = nil
fixture_port = nil
fixture_output = nil
begin
  if fixture_file
    fixture_output, writer = IO.pipe
    fixture_pid = Process.spawn('python3',File.join(ROOT,'tools/fixtures/http-playback-fixture.py'),'--file',fixture_file,out:writer)
    writer.close
    raise 'Owned HTTP fixture did not publish readiness' unless IO.select([fixture_output],nil,nil,10)
    readiness = JSON.parse(fixture_output.gets || '{}')
    fixture_port = readiness.fetch('port')
    raise 'Invalid fixture port' unless fixture_port.is_a?(Integer) && (1024..65535).cover?(fixture_port)
    arguments.concat(['--test-http-port',fixture_port.to_s])
  end
  _out, _err, status = Open3.capture3('bash',File.join(ROOT,'tools/build/install-preview.sh'),
    '--launch-current',*arguments,'--enable-control','--supervised-ui-test',Process.pid.to_s)
  raise 'Test launch failed' unless status.success?
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC)+1800
  report_file = File.expand_path('~/Library/Application Support/MTV/TestResults/ui-smoke.json')
  loop do
    current = state
    test_pid ||= current['pid'] if current && current['volatileHistory']
    report = begin JSON.parse(File.read(report_file)); rescue Errno::ENOENT,JSON::ParserError; {}; end
    if test_pid && report['pid']==test_pid && report['kind']=='ui-smoke'
      puts JSON.pretty_generate(report)
      exit(report['passed'] ? 0:1)
    end
    raise 'Test was stopped for user activity; normal mode is being restored' if test_pid && current && current['pid']!=test_pid && !current['volatileHistory']
    raise 'Test exceeded its time limit' if Process.clock_gettime(Process::CLOCK_MONOTONIC)>deadline
    sleep 0.5
  end
ensure
  if fixture_pid
    begin
      if fixture_port
        client=Net::HTTP.new('127.0.0.1',fixture_port,nil); client.open_timeout=1;client.read_timeout=1
        client.post('/shutdown','')
      end
    rescue StandardError
      # Only the child created above is eligible for cleanup below.
    end
    deadline=Process.clock_gettime(Process::CLOCK_MONOTONIC)+2
    begin
      loop do
        break if Process.waitpid(fixture_pid,Process::WNOHANG)
        if Process.clock_gettime(Process::CLOCK_MONOTONIC)>=deadline
          Process.kill('TERM',fixture_pid)
          Process.waitpid(fixture_pid)
          break
        end
        sleep 0.05
      end
    rescue Errno::ECHILD,Errno::ESRCH
    end
  end
  fixture_output&.close
  # The native guardian also covers SIGKILL/supervisor loss and reopens normal
  # MacTV after the test process exits. The installer waits for a clean quit.
  current = state
  if test_pid && current && current['pid']==test_pid && current['volatileHistory']
    path, status = Open3.capture2('ps','-p',test_pid.to_s,'-o','comm=')
    Process.kill('TERM',test_pid) if status.success? && path.strip=='/Applications/MacTV.app/Contents/MacOS/MTV'
  end
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC)+20
  loop do
    current = state
    break if current && !current['volatileHistory']
    if Process.clock_gettime(Process::CLOCK_MONOTONIC)>deadline
      warn 'Normal-mode restoration did not complete; inspect the app before further testing'
      break
    end
    sleep 0.2
  end
end
