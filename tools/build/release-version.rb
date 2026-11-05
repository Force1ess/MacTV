#!/usr/bin/env ruby
require 'open3'

module ReleaseVersion
  def self.parse(tag)
    match = /\Av(0|[1-9]\d*)\.(0|[1-9]\d*)(?:\.(0|[1-9]\d*))?(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?\z/.match(tag)
    raise 'Expected vMAJOR.MINOR or vMAJOR.MINOR.PATCH, optionally followed by -prerelease' unless match
    identifiers = match[4]&.split('.') || []
    raise 'Numeric prerelease identifiers cannot have leading zeroes' if identifiers.any? { |id| id.match?(/\A0\d+\z/) }
    {version: tag.delete_prefix('v'), bundle_version: match.captures.first(3).compact.join('.'), prerelease: !identifiers.empty?}
  end

  def self.stamp(plist, tag, build)
    version = parse(tag)
    raise 'Build number must be a positive integer' unless build.match?(/\A[1-9]\d*\z/)
    {'CFBundleShortVersionString'=>version[:bundle_version], 'CFBundleVersion'=>build,
      'MacTVReleaseVersion'=>version[:version]}.each do |key, value|
      _text, status = Open3.capture2e('/usr/libexec/PlistBuddy', '-c', "Set :#{key} #{value}", plist)
      next if status.success?
      _text, status = Open3.capture2e('/usr/libexec/PlistBuddy', '-c', "Add :#{key} string #{value}", plist)
      raise "Cannot write #{key}" unless status.success?
    end
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV.length == 3
    ReleaseVersion.stamp(*ARGV)
  elsif ARGV.length == 1
    ReleaseVersion.parse(ARGV.first).each { |key, value| puts "#{key}=#{value}" }
  else
    abort 'Usage: release-version.rb TAG | PLIST TAG BUILD'
  end
end
