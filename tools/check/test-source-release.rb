#!/usr/bin/env ruby
require 'tmpdir'
require 'fileutils'
require_relative 'check-source-release'

checks = {}
report = {'status'=>'verified','targetBuild'=>100,'checks'=>SourceReleaseCheck::V100_CHECKS.map { |name| [name,{'status'=>'passed'}] }.to_h}
issues = SourceReleaseCheck.acceptance_issues(report)
checks[:steam_window_and_voice_shortcut_are_not_full_acceptance] = %w[steamGameHandoff voiceCall].all? { |name| issues.any? { |issue| issue[:check]==name && issue[:rule]=='acceptance-evidence-missing' } }
SourceReleaseCheck::V100_EVIDENCE.each { |name, fields| fields.each { |field| report['checks'][name][field] = true } }
checks[:complete_owned_acceptance_fixture_passes] = SourceReleaseCheck.acceptance_issues(report).empty?
report['checks']['hardwareOutput']['status']='pending'
checks[:original_hardware_gate_is_preserved] = SourceReleaseCheck.acceptance_issues(report).any? { |issue| issue[:check]=='hardwareOutput' }
Dir.mktmpdir('mtv-source-check-') do |root|
  File.write(File.join(root, 'README.md'), '[Guide](guide.md)')
  File.write(File.join(root, 'guide.md'), 'Public guide')
  paths = %w[README.md guide.md]
  checks[:valid_public_links] = SourceReleaseCheck.inspect_file(root, 'README.md', paths).empty?
  checks[:private_links_rejected] = SourceReleaseCheck.inspect_file(root, 'README.md', ['README.md']).any? { |r| r[:rule] == 'link-to-unpublished-file' }
  File.write(File.join(root, 'README.md'), '[Missing](missing.md)')
  checks[:broken_links_rejected] = SourceReleaseCheck.inspect_file(root, 'README.md', paths).any? { |r| r[:rule] == 'broken-or-external-local-link' }
  File.write(File.join(root, 'secret.txt'), ['eyJ' + 'a' * 20, 'b' * 24, 'c' * 24].join('.'))
  issues = SourceReleaseCheck.inspect_file(root, 'secret.txt', ['secret.txt'])
  checks[:jwt_rejected_without_echo] = issues.any? { |r| r[:rule] == 'sensitive-material' } && !JSON.generate(issues).include?('eyJ')
  File.write(File.join(root, 'home.txt'), '/Users/' + 'fixture/' + 'private.txt')
  checks[:private_home_paths_rejected] = SourceReleaseCheck.inspect_file(root, 'home.txt', ['home.txt']).any? { |r| r[:rule] == 'sensitive-material' }
  File.symlink(File.join(root, 'guide.md'), File.join(root, 'link.md'))
  checks[:symlinks_rejected] = SourceReleaseCheck.inspect_file(root, 'link.md', ['link.md']).any? { |r| r[:rule] == 'source-symlink' }
  FileUtils.mkdir_p(File.join(root, 'Credentials'))
  File.write(File.join(root, 'Credentials', 'record'), 'fixture')
  checks[:credential_directories_rejected] = SourceReleaseCheck.inspect_file(root, 'Credentials/record', ['Credentials/record']).any? { |r| r[:rule] == 'private-or-generated-file' }
end
puts JSON.pretty_generate(checks: checks, passed: checks.values.all?)
exit(checks.values.all? ? 0 : 1)
