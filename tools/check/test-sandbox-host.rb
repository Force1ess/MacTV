#!/usr/bin/env ruby
# Compatibility entrypoint. The production sandbox host now accepts only the
# framed native broker protocol; the old direct --payload mode must stay closed.
require 'rbconfig'
if ARGV.include?('--live-services')
  abort 'Live requests require the app native broker; use the explicit live app playback tests.'
end
exec(RbConfig.ruby, File.expand_path('test-broker-host.rb', __dir__), *ARGV)
