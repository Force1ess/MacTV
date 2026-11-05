#!/usr/bin/env ruby
require 'fileutils'
require 'open3'

# Local preview signing only. Private keys never enter the repo, a keychain,
# a system trust store, command output, or a remote signing service.
ROOT = File.expand_path('../..', __dir__)
DIRECTORY = File.expand_path(ENV.fetch('MTV_SIGNING_DIRECTORY', '~/Library/Application Support/MTVDevelopment/Signing'))
TOOL = ENV.fetch('MTV_RCODESIGN', File.expand_path('~/Developer/MTVDeveloper/Tools/rcodesign-0.29.0/rcodesign'))
IDENTITY = File.join(DIRECTORY, 'preview')
FILES = [IDENTITY + '.crt', IDENTITY + '.key']
ENVIRONMENT = ENV.keys.select { |name| name.start_with?('RCODESIGN_') }.to_h { |name| [name, nil] }

def validate_identity
  node = File.lstat(DIRECTORY)
  raise 'Signing directory must be an owner-only real directory.' unless node.directory? && !node.symlink? && node.uid == Process.uid && node.mode & 0o077 == 0
  raise 'Signing directory must not resolve through a symlink.' unless File.realpath(DIRECTORY) == DIRECTORY
  FILES.each do |path|
    file = File.lstat(path)
    raise 'Signing material must be owner-only regular files.' unless file.file? && !file.symlink? && file.uid == Process.uid && file.mode & 0o077 == 0 && file.nlink == 1 && file.size > 0
  end
end
def invoke_private(*args)
  _out, _err, result = Open3.capture3(ENVIRONMENT, TOOL, '-C', '/dev/null', *args)
  raise "Local signing command failed (#{result.exitstatus || result.termsig}); existing installed app is unchanged." unless result.success?
end
begin
  case ARGV.shift
  when 'configured'
    exit 1 unless File.exist?(DIRECTORY)
    validate_identity
    exit 0
  when 'setup'
    raise 'Install the pinned rcodesign runtime first.' unless File.executable?(TOOL)
    if FILES.any? { |path| File.exist?(path) || File.symlink?(path) }
      validate_identity
      puts 'Existing local preview identity retained.'
      exit 0
    end
    old_mask = File.umask(0o077)
    begin
      FileUtils.mkdir_p(DIRECTORY, mode: 0o700)
      directory = File.lstat(DIRECTORY)
      raise 'Refusing an unsafe signing directory.' unless directory.directory? && !directory.symlink? && directory.uid == Process.uid
      File.chmod(0o700, DIRECTORY)
      raise 'Refusing a signing directory with symlink ancestors.' unless File.realpath(DIRECTORY) == DIRECTORY
      invoke_private('generate-self-signed-certificate', '--person-name', 'MTV Local Preview',
        '--country-name', 'CN', '--validity-days', '3650', '--pem-filename', IDENTITY)
      validate_identity
    ensure
      File.umask(old_mask)
    end
    puts 'Created owner-only local preview signing files. Keychain and system trust are unchanged.'
  when 'sign'
    validate_identity
    raise 'Install the pinned rcodesign runtime first.' unless File.executable?(TOOL)
    raise 'Usage: file-signing.rb sign STAGED_APP' unless ARGV.length == 1
    app = File.realpath(ARGV[0])
    stage = File.dirname(app)
    unless File.basename(app) == 'MacTV.app' && (app == File.join(ROOT, 'dist/MacTV.app') || stage.start_with?(File.join(ROOT, 'dist/build.')))
      raise 'Only the current staged MTV preview may be signed; installed apps and backups are refused.'
    end
    id, _error, result = Open3.capture3('/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleIdentifier', File.join(app, 'Contents/Info.plist'))
    raise 'Unexpected application identity.' unless result.success? && id.strip == 'local.mtv.preview'
    invoke_private('sign', '--timestamp-url', 'none', '--pem-source', FILES[0], '--pem-source', FILES[1],
      '--entitlements-xml-file', 'Contents/Helpers/MTVPluginHost.app:' + File.join(ROOT, 'config/PluginHost.entitlements'), app)
    _, _error, verified = Open3.capture3('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
    raise 'Apple signature verification failed; installed app retained.' unless verified.success?
    entitlements, err, inspected = Open3.capture3('/usr/bin/codesign', '-d', '--entitlements', ':-', File.join(app, 'Contents/Helpers/MTVPluginHost.app'))
    xml = entitlements + err
    raise 'Plugin host sandbox entitlement was not retained.' unless inspected.success? && xml.match?(/<key>com\.apple\.security\.app-sandbox<\/key>\s*<true\s*\/>/)
    puts 'File-based preview signature verified; plugin sandbox retained. Installed app unchanged.'
  else
    raise 'Usage: file-signing.rb configured | setup | sign STAGED_APP'
  end
rescue StandardError => error
  warn error.message
  exit 2
end
