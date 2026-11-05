#!/usr/bin/env ruby
require 'json'
require 'open3'
require 'timeout'

identifier = ARGV.fetch(0)
file = File.expand_path('~/Library/Application Support/MTV/TestResults/ui-smoke.json')
report = nil
begin
  Timeout.timeout(60) do
    loop do
      candidate = JSON.parse(File.read(file)) rescue nil
      if candidate && candidate['kind'] == 'quit-probe-ready' && candidate['id'] == identifier
        report = candidate; break
      end
      sleep 0.1
    end
  end
  pid = Integer(report.fetch('pid'))
  command, status = Open3.capture2('ps', '-p', pid.to_s, '-o', 'comm=')
  raise 'Unexpected target process' unless status.success? && command.strip == '/Applications/MacTV.app/Contents/MacOS/MTV'
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  Process.kill('TERM', pid)
  gone = false
  Timeout.timeout(12) do
    loop do
      begin; Process.kill(0, pid); rescue Errno::ESRCH; gone = true; break; end
      sleep 0.1
    end
  end
  checks = {playingAtRequest: report['state'] == 3 && report['elapsed'] > 2 && report['decodedFrames'] > 0,
            applicationHandlerInstalled: report['handlerInstalled'] == true, exitedOnSIGTERM: gone}
  puts JSON.pretty_generate(kind: 'playing-termination-result', id: identifier, checks: checks, passed: checks.values.all?, seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2), forceKilled: false)
rescue => error
  puts JSON.pretty_generate(kind: 'playing-termination-result', id: identifier, passed: false, error: error.message, forceKilled: false)
  exit(1)
end
