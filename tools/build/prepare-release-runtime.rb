#!/usr/bin/env ruby
# Prepare the distributable runtime, including matching source and the audio fix.
require 'json'
require 'digest'
require 'fileutils'
require 'net/http'
require 'uri'

root = File.expand_path('../..', __dir__)
Dir.chdir(root)
def run(*args)
  raise "Failed: #{args.first}" unless system(*args)
end
def download(url, destination, digest, headers: [])
  raise 'Unexpected download URL' unless url.start_with?('https://')
  unless File.file?(destination)
    arguments = headers.flat_map { |header| ['--header', header] }
    run('curl', '--fail', '--location', '--retry', '3', '--max-time', '300', *arguments, url, '-o', destination)
  end
  raise "Download verification failed: #{File.basename(destination)}" unless Digest::SHA256.file(destination).hexdigest == digest
end

config = JSON.parse(File.read('resources/native-mpv/BUILD.json'))
cache = File.join('.build/native-mpv-bottles',config.fetch('bottleTag'))
run('make', 'setup')
runtime = 'vendor/MPVNativeEngine'
materials = '.build/release-runtime-materials'
run('ruby', 'tools/build/package-native-mpv.rb', '--materials-from', cache,
  "#{runtime}/SOURCE.json", materials, '--fetch-sources')
run('ruby', 'tools/build/package-native-mpv.rb', '--bundle-notices', materials, runtime)

tools = JSON.parse(File.read('resources/native-mpv/TOOLS.json'))
downloads = '.build/release-tools'
FileUtils.mkdir_p(downloads)
pkgconf = "#{downloads}/pkgconf-#{tools.dig('pkgconfBottle','platform')}.tar.gz"
# Public GHCR bottles still require an anonymous pull token. This is not a
# GitHub account token. curl strips Authorization on cross-host redirects.
response = Net::HTTP.get_response(URI('https://ghcr.io/token?service=ghcr.io&scope=repository:homebrew/core/pkgconf:pull'))
raise 'Cannot obtain public bottle pull authorization' unless response.is_a?(Net::HTTPSuccess)
token = JSON.parse(response.body).fetch('token')
raise 'Malformed public pull authorization' unless token.match?(/\A[A-Za-z0-9._=-]+\z/)
download(tools.dig('pkgconfBottle', 'url'), pkgconf, tools.dig('pkgconfBottle', 'upstreamSHA256'),
  headers: ["Authorization: Bearer #{token}"])
run('tar', '-xzf', pkgconf, '-C', downloads)
headers = "#{downloads}/vulkan-headers.tar.gz"
download(config.dig('vulkanHeaders', 'url'), headers, config.dig('vulkanHeaders', 'sha256'))
venv = '.build/mpv-source-tools'
run('python3', '-m', 'venv', venv)
run("#{venv}/bin/python", '-m', 'pip', 'install', tools.fetch('mesonPyPIPackage'), tools.fetch('ninjaPyPIPackage'))
run('ruby', 'tools/build/rebuild-native-mpv.rb', '--cache', cache,
  '--materials', materials, '--runtime', runtime, '--pkgconf', "#{downloads}/pkgconf/#{tools.dig('pkgconfBottle', 'version')}",
  '--headers', headers, '--output', '.build/release-mpv-build')
FileUtils.mkdir_p('.build/vendor-backups')
FileUtils.mv(runtime, ".build/vendor-backups/release-base-mpv-#{Process.pid}")
FileUtils.cp_r('.build/release-mpv-build/runtime', runtime)
FileUtils.mkdir_p('dist')
run('ruby', 'tools/build/package-native-mpv.rb', '--pack-materials', materials, 'dist/MacTV-native-runtime-sources.tar.gz')
