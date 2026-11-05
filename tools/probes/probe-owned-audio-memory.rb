# Samples only this experiment and its direct VLC child, never the user's MTV.
require 'json'
mode = ARGV.fetch(0)
abort 'Expected normal or long' unless %w[normal long].include?(mode) && ARGV.length == 1
build = File.join(Dir.home, 'Developer/MTV/.build')
base = File.join(build, "owned-audio-memory-#{mode}-#{Process.pid}")
environment = { 'MTV_OWNED_AUDIO_SEEK_SEQUENCE' => '1', 'MTV_OWNED_AUDIO_LONG_ORIGIN' => mode == 'long' ? '1' : '0' }
log = File.open(base + '.log', 'wx')
pid = Process.spawn(environment, File.join(build, 'ProbeOwnedAudioOrigin'), '11.5', base + '.bin', out: log, err: log)
log.close
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
origin_peak = child_peak = samples = 0
status = nil
loop do
  rows = IO.popen(['/bin/ps', '-axo', 'pid=,ppid=,rss='], &:read).lines.map { |line| line.split.map(&:to_i) }
  origin = rows.find { |row| row[0] == pid }
  children = rows.select { |row| row[1] == pid }
  origin_peak = [origin_peak, origin ? origin[2] : 0].max
  child_peak = [child_peak, children.map { |row| row[2] }.max || 0].max
  samples += 1
  finished = Process.waitpid2(pid, Process::WNOHANG)
  if finished
    status = finished[1]
    break
  end
  sleep 0.1
end
report = { mode: mode, originPID: pid, samples: samples, requestedSampleIntervalSeconds: 0.1,
           elapsedSeconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
           sampledOriginPeakKiB: origin_peak, sampledVLCChildPeakKiB: child_peak,
           exitStatus: status.exitstatus, success: status.success?,
           physicalAudioOutputVerified: false, realLongCodecOrIndexTested: false, artifactBase: base }
File.write(base + '.json', JSON.pretty_generate(report), mode: 'wx')
puts JSON.pretty_generate(report)
abort 'Owned audio experiment failed; inspect its saved log' unless status.success?
