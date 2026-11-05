#!/usr/bin/env ruby
require 'tmpdir'
require 'fileutils'
require 'open3'

checker = File.expand_path('check-update-identity.rb', __dir__)
def create_app(root, name, version)
  path = File.join(root, "#{name}.app")
  FileUtils.mkdir_p(File.join(path, 'Contents', 'MacOS'))
  FileUtils.cp('/usr/bin/true', File.join(path, 'Contents', 'MacOS', 'Fixture'))
  File.write(File.join(path, 'Contents', 'Info.plist'), <<~XML)
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>local.mtv.signing-fixture</string>
    <key>CFBundleExecutable</key><string>Fixture</string>
    <key>CFBundleVersion</key><string>#{version}</string>
    </dict></plist>
  XML
  _, error, status = Open3.capture3('/usr/bin/codesign', '--force', '--sign', '-', path)
  abort error unless status.success?
  path
end
Dir.mktmpdir('mtv-signing-test-') do |root|
  first = create_app(root, 'First', '1')
  copy = File.join(root, 'Copy.app'); FileUtils.cp_r(first, copy)
  changed = create_app(root, 'Changed', '2')
  [[first, copy, 0], [first, changed, 2], [first, File.join(root, 'Missing.app'), 1]].each do |old, candidate, expected|
    out, err, result = Open3.capture3('ruby', checker, old, candidate)
    abort "Expected #{expected}, got #{result.exitstatus}: #{out}#{err}" unless result.exitstatus == expected
  end
end
puts '3 signing identity checks passed; no production app or privacy settings changed.'
