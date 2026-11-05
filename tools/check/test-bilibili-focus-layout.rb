#!/usr/bin/env ruby
# Real Bilibili UI navigation and SwiftUI-resolved title bounds. No screenshots,
# browser reads, credentials, playback, OS input synthesis or preference writes.
require 'json'
require 'open3'
CLI = '/Applications/MacTV.app/Contents/MacOS/mtvctl'
RUN = {}
samples = []
requested = Integer(ARGV[0] || '18')
abort 'Sample count must be 1..100' unless (1..100).cover?(requested)
def call(command, arguments = {})
  output, _, process = Open3.capture3(CLI, 'call', JSON.generate(command: command, arguments: arguments))
  result = JSON.parse(output)
  raise 'Control command failed' unless process.success? && result['ok']
  state = result.fetch('state')
  if RUN['pid'] && (state['pid'] != RUN['pid'] || state['controlRunID'] != RUN['id'])
    raise 'App instance changed during layout verification'
  end
  result
end
def wait_state(timeout = 15)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    state = call('status').fetch('state')
    return state if yield(state)
    raise 'Expected rendered layout did not arrive' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.1
  end
end
def settled_layout
  previous = nil
  stable_since = nil
  wait_state do |state|
    layout = state['mediaLayout']
    current = layout && [state['focus'], layout]
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    if current != previous
      previous = current; stable_since = now
    end
    layout && stable_since && now - stable_since >= 0.5 &&
      layout['row'] == state.dig('focus', 'row') && layout['column'] == state.dig('focus', 'column') && layout['titleFullyVisible']
  end
end
begin
  initial = call('status').fetch('state')
  raise 'Stop playback and close overlays before verification' if initial.dig('playback', 'presented') || !initial.fetch('overlays').empty?
  RUN['pid'] = initial['pid']; RUN['id'] = initial['controlRunID']
  call('module.open', {'plugin' => 'mtv.bilibili'})
  ready = wait_state(40) { |s| !s.dig('module', 'loading') }
  raise 'Actual homepage did not load' if ready.dig('module', 'failed') || ready.dig('module', 'items').to_i == 0
  listed = call('module.list', {'limit' => '100'}).dig('result', 'items')
  limit = [requested, listed.length].min
  # Current TV page: top navigation, five channels, search toolbar, video rows.
  3.times { call('input.key', {'key' => 'down'}) }
  wait_state { |s| s.dig('mediaLayout', 'itemID') == listed.first.fetch('id') }
  direction = 'right'
  limit.times do |index|
    rendered = settled_layout
    layout = rendered.fetch('mediaLayout')
    raise 'Repeated card instead of a new navigation target' if samples.any? { |s| s['itemID'] == layout['itemID'] }
    raise 'Unexpected content appeared before original homepage cards' unless listed.any? { |item| item['id'] == layout['itemID'] }
    samples << layout
    break if index + 1 == limit
    before = rendered.fetch('focus')
    moved = call('input.key', {'key' => direction}).fetch('state')
    if moved.fetch('focus') == before
      call('input.key', {'key' => 'down'})
      direction = direction == 'right' ? 'left' : 'right'
    end
  end
  puts JSON.pretty_generate(schema: 1, scope: 'real-bilibili-focus-layout', passed: samples.length == limit,
    pid: RUN['pid'], samples: samples.length, requested: requested,
    allFocusedTitlesInsideViewport: samples.all? { |s| s['titleFullyVisible'] },
    expandedTitleSamples: samples.count { |s| s.dig('title', 'height') > 42.5 },
    maximumTitleHeight: samples.map { |s| s.dig('title', 'height') }.max,
    minimumStableLayoutMS: 500,
    imagesUsed: false, physicalRemoteVerified: false)
rescue StandardError
  puts JSON.pretty_generate(schema: 1, scope: 'real-bilibili-focus-layout', passed: false,
    completedSamples: samples.length, imagesUsed: false,
    error: 'Rendered title visibility or navigation verification did not complete')
  exit 1
ensure
  begin
    call('navigate', {'section' => 'home'}) if RUN['pid']
  rescue StandardError
    # Never send cleanup to a different app instance.
  end
end
