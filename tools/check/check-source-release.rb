#!/usr/bin/env ruby
require 'json'
require 'open3'
require 'uri'

module SourceReleaseCheck
  REQUIRED = %w[README.md docs/README.en.md LICENSE docs/CONTRIBUTING.md docs/SECURITY.md .github/workflows/ci.yml
    docs/GETTING-STARTED.md docs/ARCHITECTURE.md docs/PLUGIN-DEVELOPMENT.md docs/TESTING.md
    docs/PRIVACY.md docs/ROADMAP.md docs/THIRD-PARTY.md docs/history/ACCEPTANCE.md docs/LOCAL-CONTROL.md docs/history/v100.json].freeze
  V100_CHECKS = %w[coreTests pluginTests sourceManagement modernPlayback nativeKeyboard realLibrary metadata
    chromeLogin quarkPlayback bilibiliPlayback firstFrameBudget hardwareOutput remoteControl
    upgradePermissions programmaticControl sourceReadiness distribution localization
    steamGameHandoff voiceCall].freeze
  V100_EVIDENCE = {
    'steamGameHandoff'=>%w[actualGameLaunchVerified foregroundPreservedDuringGame returnedThroughSteamToMacTV],
    'voiceCall'=>%w[callConnectionVerified physicalMicrophoneDeliveryVerified]
  }.freeze
  SENSITIVE = [
    /eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{16,}/,
    /-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----/,
    %r{/Users/[A-Za-z0-9._-]+/},
    /\b100\.(?:6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}\b/,
    /\bgh[pousr]_[A-Za-z0-9]{30,}\b/
  ].freeze

  def self.inspect_file(root, relative, public_paths)
    path = File.join(root, relative)
    issues = []
    issue = ->(rule, line = nil) { issues << {file: relative, rule: rule, line: line}.compact }
    if File.symlink?(path)
      issue.call('source-symlink'); return issues
    end
    unless File.file?(path)
      issue.call('missing-source-file'); return issues
    end
    if relative.match?(%r{(?:\A|/)(?:backups|Credentials|TestResults|node_modules|Vendor|vendor|__pycache__|\.build|dist)(?:/|\z)}) ||
      relative.match?(/\.(?:key|p12|pfx|pyc|dylib|dmg|zip|tar|gz|bz2|log)\z/i)
      issue.call('private-or-generated-file'); return issues
    end
    if File.size(path) > 8_000_000
      issue.call('oversized-source-file'); return issues
    end
    text = File.binread(path).force_encoding(Encoding::UTF_8)
    return issues unless text.valid_encoding? && !text.include?("\0")
    text.each_line.with_index(1) do |line, number|
      issue.call('sensitive-material', number) if SENSITIVE.any? { |pattern| line.match?(pattern) }
    end
    if relative.end_with?('.md')
      text.scan(/\]\((?:<([^>]+)>|([^\s)]+)(?:\s+"[^"]*")?)\)/).each do |wrapped, plain|
        target = wrapped || plain
        next if target.start_with?('#') || target.match?(%r{\Ahttps?://|\Amailto:})
        target = URI::DEFAULT_PARSER.unescape(target.split('#', 2).first.to_s)
        destination = File.expand_path(target, File.dirname(path))
        unless destination.start_with?(root + '/') && File.exist?(destination)
          issue.call('broken-or-external-local-link'); next
        end
        linked = destination.delete_prefix(root + '/')
        unless public_paths.include?(linked) || public_paths.any? { |entry| entry.start_with?(linked + '/') }
          issue.call('link-to-unpublished-file')
        end
      end
    end
    issues
  end

  def self.acceptance_issues(report)
    issues = []
    V100_CHECKS.each do |name|
      issues << {file: 'docs/history/v100.json', rule: 'acceptance-not-passed', check: name} unless report.dig('checks', name, 'status') == 'passed'
    end
    V100_EVIDENCE.each do |name, fields|
      next unless report.dig('checks',name,'status') == 'passed'
      fields.each do |field|
        issues << {file:'docs/history/v100.json',rule:'acceptance-evidence-missing',check:name,field:field} unless report.dig('checks',name,field) == true
      end
    end
    issues << {file: 'docs/history/v100.json', rule: 'release-not-approved'} unless report['status'] == 'verified' && report['targetBuild'] == 100
    issues
  end

  def self.run(root, require_v100: false)
    stdout, status = Open3.capture2('git', '-C', root, 'ls-files', '-z', '--cached', '--others', '--exclude-standard')
    raise 'Cannot list project source files' unless status.success?
    staged, staged_status = Open3.capture2('git', '-C', root, 'ls-files', '--stage', '-z')
    raise 'Cannot list pinned submodules' unless staged_status.success?
    submodules = staged.split("\0").select { |row| row.start_with?('160000 ') }.map { |row| row.split("\t", 2).last }
    paths = stdout.split("\0").uniq.sort.reject { |path| submodules.include?(path) }
    issues = (REQUIRED - paths).map { |file| {file: file, rule: 'missing-project-document'} }
    paths.each { |path| issues.concat(inspect_file(root, path, paths)) }
    if require_v100
      report = JSON.parse(File.read(File.join(root, 'docs/history/v100.json')))
      issues.concat(acceptance_issues(report))
      plist = File.read(File.join(root, 'config/Info.plist'))
      issues << {file: 'config/Info.plist', rule: 'not-build-100'} unless plist.match?(%r{<key>CFBundleVersion</key>\s*<string>100</string>})
    end
    {schema: 1, scope: require_v100 ? 'v100-acceptance' : 'public-source', files: paths.length,
      passed: issues.empty?, issues: issues, credentialsPrinted: false}
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    abort 'Usage: check-source-release.rb [--require-v100]' unless ARGV.empty? || ARGV == ['--require-v100']
    result = SourceReleaseCheck.run(File.expand_path('../..', __dir__), require_v100: ARGV.include?('--require-v100'))
    puts JSON.pretty_generate(result)
    exit(result[:passed] ? 0 : 1)
  rescue StandardError
    warn JSON.generate(schema: 1, passed: false, error: 'Source release inspection failed; inspect local inputs without publishing their contents')
    exit 1
  end
end
