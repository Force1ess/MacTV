#!/usr/bin/env ruby
# Observe only this MTV process. Never accepts an older run and never kills it.
require 'json'
require 'open3'

pid = Integer(ARGV.fetch(0))
command, status = Open3.capture2('ps', '-p', pid.to_s, '-o', 'comm=')
abort 'Expected PID is not the installed MTV app' unless status.success? && command.strip == '/Applications/MacTV.app/Contents/MacOS/MTV'
path = File.expand_path('~/Library/Application Support/MTV/TestResults/ui-smoke.json')
timeout = Integer(ARGV[1] || 120)
abort 'Observation timeout must be between 30 and 600 seconds' unless (30..600).cover?(timeout)
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
loop do
  report = begin
    JSON.parse(File.read(path))
  rescue Errno::ENOENT, JSON::ParserError
    {}
  end
  if report['pid'] == pid && report['kind'] == 'ui-smoke'
    failed = report.fetch('checks').reject { |_, passed| passed == true }.keys
    summary = {pid: pid, runDirectory: report['runDirectory'],
      passed: report['passed'] == true && failed.empty?, checks: report['checks'].length,
      failed: failed}
    %w[verificationScope requestedScopeFullyVerified nativePointerDragVerified physicalRemoteOrTouchpadVerified
      realNASOrChromeSessionVerified macOSAudioTranscriptionVerified physicalAudioOutputVerified].each do |key|
      summary[key] = report[key] if report.key?(key)
    end
    puts JSON.pretty_generate(summary)
    exit(report['passed'] == true && failed.empty? ? 0 : 1)
  end
  begin
    Process.kill(0, pid)
  rescue Errno::ESRCH
    abort 'MTV exited before producing its own final report'
  end
  abort 'Timed out waiting for this process; previous results were not accepted' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
  sleep 0.25
end
