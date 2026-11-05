#!/usr/bin/env ruby
require 'json'
require 'open3'
require 'timeout'

probe = ARGV.fetch(0)
fixture_root = ARGV.fetch(1)
engine_root = ARGV[2]
results = []
Dir.glob(File.join(fixture_root, '*')).select { |path| ['.mp4', '.mkv'].include?(File.extname(path)) }.sort.each do |path|
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  row = {file: File.basename(path), engine: engine_root ? 'libVLC' : 'AVFoundation', generatedFixture: true}
  arguments = engine_root ? [probe, engine_root, path] : [probe, path]
  Open3.popen3(*arguments) do |stdin, stdout, stderr, process|
    stdin.close
    out_reader = Thread.new { stdout.read }
    err_reader = Thread.new { stderr.read }
    begin
      Timeout.timeout(30) { process.join }
      output = out_reader.value
      row[:result] = JSON.parse(output)
      row[:exitCode] = process.value.exitstatus
    rescue Timeout::Error
      Process.kill('TERM', process.pid)
      process.join
      row[:error] = 'Probe exceeded 30-second limit'
    rescue JSON::ParserError
      row[:error] = 'Probe returned no valid JSON'
    ensure
      stdout.close unless stdout.closed?; stderr.close unless stderr.closed?
      out_reader.join; err_reader.join
    end
  end
  row[:seconds] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)
  results << row
end
puts JSON.pretty_generate(kind: 'generated-playback-matrix', results: results, hdrOutputVerified: false, physicalAudioVerified: false)
