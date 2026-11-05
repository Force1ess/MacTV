#!/usr/bin/env ruby
# Integration test against the app's generated documentation library only.
require 'json'
require 'open3'
CLI = ARGV.fetch(0, '/Applications/MacTV.app/Contents/MacOS/mtvctl')
def call(command, arguments = {})
  out, _err, status = Open3.capture3(CLI, 'call', JSON.generate(command:command,arguments:arguments))
  value = JSON.parse(out)
  raise 'Native module control failed' unless status.success? && value['ok']
  value
end
def wait
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
  loop do
    value = yield
    return value if value
    raise 'Native module state timed out' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    sleep 0.1
  end
end
def items
  wait do
    value = call('module.list', {'limit'=>'100'})
    raise 'Native module reported a source failure' if value.dig('state','module','failed')
    value.dig('state','module','loading') ? nil : value.dig('result','items')
  end
end
checks = {}
begin
  raise 'Requires --ui-smoke --documentation-preview' unless call('status').dig('state','documentationPreview')
  call('module.open', {'plugin'=>'community.gallery'})
  roots = items; checks['rootIsExplicitGeneratedLibrary'] = roots.any? { |item| item['id']=='root-0' }
  checks['cloudProviderEntryIsSeparateFromLocalSources'] = roots.any? { |item| item['id']=='quark:0' }
  call('item.activate', {'id'=>roots.find { |item| item['id']=='root-0' }.fetch('id')})
  albums = items; checks['generatedAlbumsAvailable'] = albums.length == 6
  call('item.activate', {'id'=>albums.fetch(0).fetch('id')})
  photos = items; checks['nativePhotoItemsAvailable'] = photos.length == 2
  call('item.activate', {'id'=>photos.fetch(0).fetch('id')})
  first = wait { value=call('status').dig('state','nativeMedia'); value['imageWidth'].to_f > 0 ? value : nil }
  checks['boundedNativeImageDecode'] = first['presented'] && first['imageHeight'].to_f > 0
  call('input.key', {'key'=>'right'})
  second = wait { value=call('status').dig('state','nativeMedia'); value['id']!=first['id'] && value['imageWidth'].to_f>0 ? value : nil }
  checks['remoteMovesToNextImage'] = second['id'] != first['id']
  checks['backspaceClosesImage'] = !call('input.key', {'key'=>'backspace'}).dig('state','nativeMedia','presented')
  puts JSON.pretty_generate(scope:'generated-native-library',checks:checks,passed:checks.values.all?,privateMediaRead:false)
  exit(checks.values.all? ? 0 : 1)
ensure
  call('navigate', {'section'=>'home'})
end
