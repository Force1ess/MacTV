#!/usr/bin/env ruby
# Offline source rebuild. Never installs formulae or modifies an input runtime.
require 'optparse'
require_relative 'native-runtime-materials'

module RebuildNativeMPV
  def self.run(*args, env: {})
    raise "Command failed: #{File.basename(args.first)}" unless system(env, *args)
  end
  def self.output(command)
    value, status = Open3.capture2e(*command)
    raise "Command failed: #{File.basename(command.first)}" unless status.success?
    value.strip
  end
  def self.pkgconfig(inventory, cache, staged, pc, header_root, sdk: nil)
    roots = inventory.fetch('components').map do |item|
      name = item.fetch('name'); directory = item.fetch('directory')
      raise 'Invalid frozen header path' unless name.match?(/\A[a-z0-9][a-z0-9+@._-]*\z/) && directory.start_with?(name + '/') && !directory.split('/').include?('..')
      root = File.join(cache, name, directory)
      raise 'Missing frozen header bottle' unless File.directory?(root)
      raise 'Frozen headers escaped their cache' unless File.realpath(root).start_with?(File.realpath(cache) + '/')
      [item.fetch('name'), root]
    end.to_h
    link_root = File.join(File.dirname(staged), 'link-libraries')
    raise 'Linked build-library directory' if File.symlink?(link_root)
    FileUtils.mkdir_p(link_root)
    libraries = Dir.children(File.join(staged, 'lib')).select { |name| name.end_with?('.dylib') }
    roots.each_value do |root|
      identities = libraries.map do |name|
        file = File.join(root, 'lib', name)
        File.exist?(file) ? [File.realpath(file), name] : nil
      end.compact.to_h
      Dir.glob(File.join(root, 'lib', '*.dylib')).each do |file|
        name = identities[File.realpath(file)]
        next unless name
        alias_path = File.join(link_root, File.basename(file))
        target = File.join(staged, 'lib', name)
        if File.exist?(alias_path) || File.symlink?(alias_path)
          raise 'Conflicting frozen linker alias' unless File.symlink?(alias_path) && File.realpath(alias_path) == File.realpath(target)
        else
          File.symlink(target, alias_path)
        end
      end
    end
    roots.each do |name, root|
      Dir.glob(File.join(root, '{lib,share}', 'pkgconfig', '*.pc')).each do |file|
        text = File.read(NativeRuntimeMaterials.regular!(file))
        text = text.gsub(/^prefix=.*$/, "prefix=#{root}")
          .gsub(/^libdir=.*$/, "libdir=#{link_root}")
        text = text.gsub(/^includedir=.*$/, "includedir=#{header_root}/include") if name == 'vulkan-loader'
        roots.each do |dependency, path|
          text = text.gsub(%r{(?:@@HOMEBREW_PREFIX@@|/opt/homebrew)/opt/#{Regexp.escape(dependency)}(?=/|\s|\z)}, path)
            .gsub(%r{(?:@@HOMEBREW_CELLAR@@|/opt/homebrew/Cellar)/#{Regexp.escape(dependency)}/[^/\s]+}, path)
            .gsub(path + '/lib', link_root)
        end
        text = text.gsub('@@HOMEBREW_PREFIX@@', '${prefix}')
        raise "Unresolved frozen build path in #{File.basename(file)}" if text.include?('@@HOMEBREW')
        File.write(File.join(pc, File.basename(file)), text)
      end
    end
    # These are SDK/system libraries already used by the frozen runtime, not
    # replacement formulae. Apple provides headers/stubs but no .pc files.
    sdk ||= output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'])
    [['zlib', 'zlib.h', /#define ZLIB_VERSION "([0-9.]+)"/, 'z'],
      ['bzip2', 'bzlib.h', /bzip2\/libbzip2 version ([0-9.]+)/, 'bz2']].each do |name, header, pattern, library|
      next if roots.key?(name)
      version = File.read(File.join(sdk, 'usr/include', header)).match(pattern)
      raise 'Unidentified SDK dependency' unless version
      File.write(File.join(pc, name + '.pc'), "Name: #{name}\nDescription: Apple SDK system #{name}\nVersion: #{version[1]}\nLibs: -l#{library}\nCflags: -I#{sdk}/usr/include\n")
    end
  end
  def self.main(options)
    project = File.expand_path('../..', __dir__)
    configuration = File.join(project, 'resources/native-mpv/BUILD.json')
    config = JSON.parse(File.read(configuration))
    %w[cache materials runtime pkgconf headers output].each { |key| raise "Missing --#{key}" unless options[key] }
    raise 'ARM macOS source build required' unless output(['/usr/bin/uname', '-sm']) == 'Darwin arm64'
    inputs = %w[cache materials runtime pkgconf headers].map { |key| File.realpath(options.fetch(key)) }
    destination = File.expand_path(options.fetch('output'))
    raise 'Build workspace overlaps inputs' if inputs.any? { |path| destination == path || destination.start_with?(path + '/') || path.start_with?(destination + '/') }
    raise 'Linked build workspace' if File.symlink?(destination)
    FileUtils.mkdir_p(destination)
    lock = File.open(File.join(destination, 'LOCK'), File::RDWR | File::CREAT, 0600)
    raise 'Build workspace is in use' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
    cache, materials, runtime, pkgconf, headers = inputs
    metadata = JSON.parse(File.read(NativeRuntimeMaterials.material_path(runtime, 'SOURCE.json')))
    raise 'Wrong base MPV version' unless metadata.dig('formulae', 'mpv', 'version') == config.fetch('baseVersion')
    inventory = JSON.parse(File.read(NativeRuntimeMaterials.material_path(materials, 'MATERIALS.json')))
    raise 'Runtime/header component mismatch' unless inventory.fetch('components').map { |item| item.fetch('name') }.sort == metadata.fetch('formulae').keys.sort
    inventory.fetch('components').each do |item|
      raise 'Runtime/header version mismatch' unless item.fetch('version') == metadata.fetch('formulae').fetch(item.fetch('name')).fetch('version')
    end
    component = inventory.fetch('components').find { |item| item['name'] == 'mpv' }
    raise 'Missing frozen MPV source inventory' unless inventory['materialsComplete'] == true && component
    sources = component.fetch('sources').map { |source| [source, NativeRuntimeMaterials.material_path(materials, source.fetch('path'))] }
    base = sources.find { |source, _| source['path'].end_with?('.tar.gz') }
    raise 'Frozen MPV source changed' unless base && Digest::SHA256.file(base.last).hexdigest == base.first.fetch('sha256')
    raise 'Vulkan headers changed' unless Digest::SHA256.file(headers).hexdigest == config.dig('vulkanHeaders', 'sha256')
    patch = NativeRuntimeMaterials.material_path(File.dirname(configuration), config.fetch('patch'))
    identity = {'schema'=>1, 'configuration'=>config, 'baseRuntimeFormulae'=>metadata.fetch('formulae')}
    state = File.join(destination, 'STATE.json')
    source = File.join(destination, 'source')
    staged = File.join(destination, 'runtime')
    pc = File.join(destination, 'pkgconfig')
    header_root = File.join(destination, 'vulkan-headers')
    tools = File.join(destination, 'tools')
    if File.file?(state)
      raise 'Build inputs changed; choose a separate workspace' unless JSON.parse(File.read(state)) == identity
    else
      raise 'Incomplete prior preparation; inspect before reusing this workspace' unless Dir.children(destination) == ['LOCK']
      puts JSON.generate(phase: 'prepare', baseVersion: config['baseVersion'], upstreamFix: config['upstreamFix'])
      FileUtils.mkdir_p([source, pc, header_root, tools])
      FileUtils.cp_r(runtime, staged)
      run('/usr/bin/tar', '-xzf', base.last, '--strip-components=1', '-C', source)
      run('/usr/bin/tar', '-xzf', headers, '--strip-components=1', '-C', header_root)
      (sources.select { |item, _| item['path'].end_with?('.patch') }.map(&:last) + [patch]).each do |file|
        run('/usr/bin/patch', '-d', source, '-p1', '--batch', '--forward', '--fuzz=0', '-i', file)
      end
      pkg_stage = File.join(tools, 'pkgconf')
      FileUtils.cp_r(pkgconf, pkg_stage)
      binary = File.join(pkg_stage, 'bin/pkgconf')
      dylib = Dir.glob(File.join(pkg_stage, 'lib/libpkgconf.*.dylib')).find { |file| !File.symlink?(file) }
      raise 'Incomplete pkgconf bottle' unless File.executable?(binary) && dylib
      lines = output(['/usr/bin/otool', '-L', binary]).lines.drop(1).map { |line| line.strip.split.first }
      lines.reject { |name| name.start_with?('/usr/lib/', '/System/Library/') }.each do |name|
        raise 'Unexpected pkgconf dependency' unless File.basename(name) == File.basename(dylib)
        run('/usr/bin/install_name_tool', '-change', name, '@loader_path/../lib/' + File.basename(dylib), binary)
      end
      [dylib, binary].each { |file| run('/usr/bin/codesign', '--force', '--sign', '-', file) }
      File.write(state, JSON.pretty_generate(identity) + "\n")
    end
    pkgconfig(inventory, cache, staged, pc, header_root)
    meson = ENV.fetch('MTV_MESON', File.join(project, '.build/mpv-source-tools/bin/meson'))
    ninja = ENV.fetch('MTV_NINJA', File.join(project, '.build/mpv-source-tools/bin/ninja'))
    pkg_binary = File.join(tools, 'pkgconf/bin/pkgconf')
    versions = {}
    {'meson'=>meson, 'ninja'=>ninja, 'pkgconf'=>pkg_binary}.each do |name, file|
      version = output([file, '--version']); versions[name] = version
      # The pinned PyPI Ninja wheel reports its upstream vendor build suffix.
      release = name == 'ninja' ? version.split('.git.', 2).first : version
      raise "Unexpected #{name} version" unless release == config.fetch(name + 'Version')
    end
    env = {'PATH'=>File.dirname(ninja) + ':' + ENV.fetch('PATH'), 'PKG_CONFIG'=>pkg_binary,
      'PKG_CONFIG_LIBDIR'=>pc, 'PKG_CONFIG_PATH'=>'', 'MACOSX_DEPLOYMENT_TARGET'=>config.fetch('deploymentTarget')}
    build = File.join(destination, 'build')
    arguments = [meson, 'setup', build, source, '--buildtype=release', '--wrap-mode=nodownload', *config.fetch('mesonOptions')]
    # MPV's custom Swift command does not inherit MACOSX_DEPLOYMENT_TARGET.
    arguments << "-Dswift-flags=-target arm64-apple-macosx#{config.fetch('deploymentTarget')}"
    arguments.concat(['--clearcache', '--reconfigure']) if File.file?(File.join(build, 'meson-private/coredata.dat'))
    puts JSON.generate(phase: 'configure')
    run(*arguments, env: env)
    puts JSON.generate(phase: 'compile', jobs: 4)
    run(meson, 'compile', '-C', build, '-j', '4', env: env)
    swift_archive = File.join(build,'osdep/mac/swift.o')
    if File.file?(swift_archive)
      swift_minimum = NativeRuntimeMaterials.minimum_macos_from_build_commands(output(['/usr/bin/otool','-l',swift_archive]))
      NativeRuntimeMaterials.require_macos_compatibility!(swift_minimum,target:config.fetch('deploymentTarget'))
    end
    library = Dir.glob(File.join(build, 'libmpv.2*.dylib')).find { |file| File.file?(file) && !File.symlink?(file) }
    raise 'No rebuilt libmpv' unless library
    minimum = NativeRuntimeMaterials.minimum_macos_from_build_commands(output(['/usr/bin/vtool','-show-build',library]))
    NativeRuntimeMaterials.require_macos_compatibility!(minimum,target:config.fetch('deploymentTarget'))
    target = File.join(staged, 'lib/libmpv.2.dylib')
    FileUtils.cp(library, target)
    run('/usr/bin/install_name_tool', '-id', '@rpath/libmpv.2.dylib', target)
    output(['/usr/bin/otool', '-L', target]).lines.drop(1).map { |line| line.strip.split.first }.each do |dependency|
      next if dependency.start_with?('/usr/lib/', '/System/Library/') || dependency == '@rpath/libmpv.2.dylib'
      name = File.basename(dependency)
      raise 'Rebuilt dependency is outside the frozen runtime' unless File.file?(File.join(staged, 'lib', name))
      run('/usr/bin/install_name_tool', '-change', dependency, '@loader_path/' + name, target)
    end
    output(['/usr/bin/otool', '-l', target]).scan(/cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset \d+\)/).flatten.each do |path|
      next if path.start_with?('@', '/usr/lib/', '/System/Library/')
      run('/usr/bin/install_name_tool', '-delete_rpath', path, target)
    end
    run('/usr/bin/strip', '-S', target)
    run('/usr/bin/codesign', '--force', '--sign', '-', target)
    offer = File.join(staged, 'source/mpv-local-build')
    FileUtils.mkdir_p(File.join(offer, 'inputs'))
    sources.each { |_, file| FileUtils.cp(file, File.join(offer, 'inputs', File.basename(file))) }
    FileUtils.cp(headers, File.join(offer, 'inputs', File.basename(headers)))
    %w[tools/build/rebuild-native-mpv.rb tools/build/native-runtime-materials.rb].each do |relative|
      file = File.join(offer, relative); FileUtils.mkdir_p(File.dirname(file)); FileUtils.cp(File.join(project, relative), file)
    end
    FileUtils.mkdir_p(File.join(offer,'resources'))
    FileUtils.copy_entry(File.join(project, 'resources/native-mpv'), File.join(offer, 'resources/native-mpv'))
    metadata['source'] = 'Frozen Homebrew runtime dependencies; libmpv rebuilt from matching source with the documented upstream CoreAudio fix'
    metadata['mpvLocalBuild'] = {'baseVersion'=>config['baseVersion'], 'upstreamFix'=>config['upstreamFix'],
      'sourceInputs'=>'source/mpv-local-build', 'preApplicationSigningSHA256'=>Digest::SHA256.file(target).hexdigest,
      'baseBottleIsNotTheRebuiltBinary'=>true, 'buildTools'=>versions, 'legalReviewComplete'=>false}
    File.write(File.join(staged, 'SOURCE.json'), JSON.pretty_generate(metadata) + "\n")
    receipt = {'schema'=>1, 'phase'=>'complete', 'upstreamFix'=>config['upstreamFix'], 'runtime'=>staged,
      'systemPackagesChanged'=>false, 'inputRuntimeChanged'=>false, 'legalReviewComplete'=>false}
    File.write(File.join(destination, 'RESULT.json'), JSON.pretty_generate(receipt) + "\n")
    puts JSON.generate(receipt)
  ensure
    lock.close if lock
  end
end

if $PROGRAM_NAME == __FILE__
  STDOUT.sync = true
  options = {}
  parser = OptionParser.new { |value| %w[cache materials runtime pkgconf headers output].each { |key| value.on("--#{key} PATH") { |path| options[key] = path } } }
  parser.parse!
  abort 'Unexpected arguments' unless ARGV.empty?
  begin RebuildNativeMPV.main(options)
  rescue StandardError => error
    warn error.message
    exit 1
  end
end
