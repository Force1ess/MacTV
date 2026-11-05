#!/usr/bin/env ruby
# Read-only check: an update must satisfy the installed app's signing identity
# in both directions. A broader replacement requirement is not accepted either.
require 'open3'

abort 'Usage: check-update-identity.rb INSTALLED_APP CANDIDATE_APP' unless ARGV.length == 2
installed, candidate = ARGV
def requirement(path)
  out, err, status = Open3.capture3('/usr/bin/codesign', '-d', '-r-', path)
  raise "Cannot read signature: #{path}" unless status.success?
  value = (out + err).lines.map { |line| line[/^(?:# )?designated => (.+)$/, 1] }.compact.first
  raise "No designated signing requirement: #{path}" if value.nil? || value.empty?
  value
end
begin
  old_requirement = requirement(installed)
  new_requirement = requirement(candidate)
  compatible = [[candidate, old_requirement], [installed, new_requirement]].all? do |path, expected|
    _, _, status = Open3.capture3('/usr/bin/codesign', '--verify', '--strict', '-R', '=' + expected, path)
    status.success?
  end
  unless compatible
    warn 'Signing identity changed: replacing this app can invalidate its existing macOS privacy permissions.'
    exit 2
  end
  puts 'App signing requirement preserved.'
  helpers = [installed, candidate].map { |path| File.join(path, 'Contents/MacOS/MTVChromeBridge') }
  if helpers.all? { |path| File.file?(path) }
    fingerprints = helpers.map do |path|
      out, err, result = Open3.capture3('/usr/bin/codesign', '-d', '--verbose=4', path)
      raise 'Cannot inspect Chrome component identity.' unless result.success?
      (out + err).lines.map { |line| line[/^CDHash=([0-9a-f]+)$/, 1] }.compact.first
    end
    raise 'Chrome component has no signed content identity.' if fingerprints.any?(&:nil?)
    if fingerprints.uniq.length == 1
      puts 'Chrome login component identity preserved.'
    else
      puts 'Chrome login component updated; one explicit system authorization may be required.'
    end
  end
rescue StandardError => error
  warn error.message
  exit 1
end
