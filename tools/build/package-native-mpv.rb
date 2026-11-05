#!/usr/bin/env ruby
# Build a private relocatable libmpv runtime from verified Homebrew bottles.
# Downloads/cache extraction only: never installs/upgrades system formulae.
require 'json'
require 'fileutils'
require 'open3'
require 'pathname'
require 'time'
require_relative 'native-runtime-materials'

if ['--pack-materials','--bundle-notices'].include?(ARGV.first)
  abort 'Usage: package-native-mpv.rb --pack-materials|--bundle-notices MATERIALS OUTPUT' unless ARGV.length == 3
  result = ARGV.first == '--pack-materials' ? NativeRuntimeMaterials.pack(ARGV[1],ARGV[2]) : NativeRuntimeMaterials.bundle_notices(ARGV[1],ARGV[2])
  puts JSON.pretty_generate(result)
  exit 0
end

if ARGV.first == '--materials-from'
  abort 'Usage: package-native-mpv.rb --materials-from CACHE SOURCE.json DESTINATION [--fetch-sources]' unless
    [4,5].include?(ARGV.length) && (ARGV.length == 4 || ARGV.last == '--fetch-sources')
  report = NativeRuntimeMaterials.collect(cache: ARGV[1],metadata: ARGV[2],destination: ARGV[3],fetch: ARGV.length == 5)
  puts JSON.pretty_generate({'components'=>report['components'].length,'missingSources'=>report['missingSources'].length,
    'missingNotices'=>report['missingNotices'],'materialsComplete'=>report['materialsComplete'],'legalReviewComplete'=>false})
  exit(report['materialsComplete'] ? 0:1)
end
abort 'Unexpected runtime packaging arguments' unless ARGV.empty?

project = File.expand_path('../..', __dir__)
configuration = JSON.parse(File.read(File.join(project, 'resources/native-mpv/BUILD.json')))
tag = configuration.fetch('bottleTag')
raise 'Unsupported runtime bottle platform' unless tag.match?(/\Aarm64_[a-z_]+\z/)
lock = JSON.parse(File.read(File.join(project, 'resources/native-mpv/BOTTLES.json')))
raise 'Runtime bottle lock does not match the build target' unless lock['schema'] == 1 &&
  lock['platform'] == tag && lock.dig('formulae','mpv','version') == configuration.fetch('baseVersion')
locked_formulae = lock.fetch('formulae')
env = {'HOMEBREW_NO_AUTO_UPDATE'=>'1', 'HOMEBREW_NO_INSTALL_CLEANUP'=>'1'}
cache = File.join(project,'.build','native-mpv-bottles',tag)
stage = File.join(project,'.build',"native-mpv-runtime-#{Process.pid}")
FileUtils.mkdir_p([cache, File.join(stage,'lib'), File.join(stage,'licenses')])
def run(env, *args)
  output, status = Open3.capture2e(env,*args)
  raise "#{args.first} failed: #{output[-3000..] || output}" unless status.success?
  output
end
formulae = {}
extract = lambda do |name|
  return formulae.fetch(name).fetch('root') if formulae.key?(name)
  raise 'Invalid dependency formula' unless name.match?(/\A[a-z0-9][a-z0-9+@._-]*\z/)
  puts "Fetching #{name}"; STDOUT.flush
  metadata = locked_formulae.fetch(name) { raise "Missing pinned #{tag} bottle for #{name}" }
  bottle = metadata.fetch('bottle')
  digest = bottle.fetch('sha256'); url = bottle.fetch('url')
  raise 'Invalid official bottle identity' unless digest.match?(/\A[0-9a-f]{64}\z/) &&
    url.start_with?('https://ghcr.io/v2/homebrew/core/') && url.end_with?('/blobs/sha256:'+digest)
  archive = File.join(cache,"#{name}-#{digest}.tar.gz")
  unless File.file?(archive) && Digest::SHA256.file(archive).hexdigest == digest
    package = URI(url).path.split('/blobs/').first.delete_prefix('/v2/')
    token_url = 'https://ghcr.io/token?' + URI.encode_www_form(service:'ghcr.io',scope:"repository:#{package}:pull")
    token = JSON.parse(run(env,'/usr/bin/curl','-q','--fail','--silent','--show-error','--max-time','60',token_url)).fetch('token')
    raise 'Malformed public pull token' unless token.match?(/\A[A-Za-z0-9._=+\/-]+\z/)
    NativeRuntimeMaterials.download(url,archive,digest,headers:["Authorization: Bearer #{token}"])
  end
  root = File.join(cache,name)
  FileUtils.mkdir_p(root)
  run(env,'/usr/bin/tar','-xzf',archive,'-C',root)
  package_version = metadata.fetch('packageDirectory')
  raise "Invalid pinned package directory: #{name}" unless package_version.match?(/\A[0-9A-Za-z][0-9A-Za-z._+-]*\z/)
  package_root = File.join(root,name,package_version)
  raise "Bottle layout unsupported: #{name}" unless File.directory?(package_root)
  formulae[name] = metadata.merge('root'=>package_root)
  license_source = File.join(package_root,'share','licenses')
  FileUtils.cp_r(license_source,File.join(stage,'licenses',name)) if File.directory?(license_source)
  notice_target = File.join(stage,'licenses',name)
  Dir.children(package_root).select { |item| item.match?(NativeRuntimeMaterials::NOTICE) }.each do |item|
    path = File.join(package_root,item)
    next unless File.file?(path)
    NativeRuntimeMaterials.regular!(path)
    FileUtils.mkdir_p(notice_target); FileUtils.cp(path,File.join(notice_target,item))
  end
  package_root
end
root = extract.call('mpv')
first = File.join(root,'lib','libmpv.2.dylib')
raise 'Bottle has no libmpv' unless File.file?(first)
molten = File.join(extract.call('molten-vk'),'lib','libMoltenVK.dylib')
queue = [first,molten]
images = {}
resolve = lambda do |dependency, source|
  normalized = dependency.sub('@@HOMEBREW_PREFIX@@','/opt/homebrew').sub('@@HOMEBREW_CELLAR@@','/opt/homebrew/Cellar')
  if (match = normalized.match(%r{\A/opt/homebrew/opt/([^/]+)/(.*)\z}))
    File.join(extract.call(match[1]),match[2])
  elsif (match = normalized.match(%r{\A/opt/homebrew/Cellar/([^/]+)/[^/]+/(.*)\z}))
    File.join(extract.call(match[1]),match[2])
  elsif normalized.start_with?('@loader_path/')
    File.expand_path(normalized.delete_prefix('@loader_path/'),File.dirname(source))
  elsif normalized.start_with?('@rpath/')
    File.join(File.dirname(source),normalized.delete_prefix('@rpath/'))
  else
    raise "Unknown non-system dependency: #{dependency}"
  end
end
until queue.empty?
  requested = queue.shift
  source = File.realpath(requested)
  raise 'Dependency escaped extracted bottles' unless source.start_with?(cache + '/')
  name = File.basename(requested)
  next if images.key?(name)
  destination = File.join(stage,'lib',name)
  FileUtils.cp(source,destination)
  FileUtils.chmod(0o755,destination)
  dependencies = run(env,'/usr/bin/otool','-arch','arm64','-L',source).lines.drop(1).map { |line| line.strip.split(' (').first unless line.strip.empty? }.compact
  changes = {}
  dependencies.each do |dependency|
    next if dependency.start_with?('/usr/lib/','/System/Library/')
    # otool's first install-name entry is the dylib itself.
    next if File.basename(dependency) == name || File.basename(dependency) == File.basename(source)
    path = resolve.call(dependency,source)
    raise "Missing dependency #{dependency}" unless File.file?(path)
    target = File.basename(path)
    changes[dependency] = target
    queue << path
  end
  build_commands = run(env,'/usr/bin/vtool','-show-build',source)
  minimum = NativeRuntimeMaterials.minimum_macos_from_build_commands(build_commands)
  target = configuration.fetch('deploymentTarget')
  NativeRuntimeMaterials.require_macos_compatibility!(minimum,target:target)
  images[name] = {'source'=>source, 'dependencies'=>changes, 'minimumMacOS'=>minimum}
end
images.each do |name, information|
  file = File.join(stage,'lib',name)
  args = ['/usr/bin/install_name_tool','-id',"@rpath/#{name}"]
  information['dependencies'].each { |before,after| args += ['-change',before,"@loader_path/#{after}"] }
  run(env,*args,file)
  run(env,'/usr/bin/codesign','--force','--sign','-',file)
end
FileUtils.mkdir_p(File.join(stage,'icd'))
File.write(File.join(stage,'icd','MoltenVK_icd.json'),JSON.pretty_generate({'file_format_version'=>'1.0.0',
  'ICD'=>{'library_path'=>'../lib/libMoltenVK.dylib','api_version'=>'1.3.0'}}))
File.write(File.join(stage,'SOURCE.json'),JSON.pretty_generate({'packagedAt'=>Time.now.utc.iso8601,
  'source'=>'Homebrew verified bottles; libmpv native Vulkan build',
  'bottleTag'=>tag, 'deploymentTarget'=>configuration.fetch('deploymentTarget'), 'formulae'=>formulae.transform_values { |v| v.reject { |k,_| k == 'root' } },
  'images'=>images.transform_values { |v| v.reject { |k,_| k == 'source' } }}))
destination = File.join(project,'Vendor','MPVNativeEngine')
FileUtils.mkdir_p(File.join(project,'Vendor'))
if File.exist?(destination)
  backup = File.join(project,'.build','vendor-backups',"MPVNativeEngine-#{Time.now.to_i}-#{Process.pid}")
  FileUtils.mkdir_p(File.dirname(backup)); FileUtils.mv(destination,backup)
end
FileUtils.mv(stage,destination)
puts "Packaged #{images.length} images from #{formulae.length} verified bottles: #{destination}"
