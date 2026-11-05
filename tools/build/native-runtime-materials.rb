# Frozen Homebrew bottle evidence for the runtime actually packaged. This module
# never evaluates formula Ruby, installs packages or changes the application.
require 'json'
require 'fileutils'
require 'digest'
require 'uri'
require 'open3'
require 'tmpdir'
require 'find'
require 'rubygems/version'

module NativeRuntimeMaterials
  # Read deployment commands, not the SDK version used to compile the binary.
  def self.minimum_macos_from_build_commands(output)
    versions = output.split(/(?=Load command \d+)/).map do |command|
      if command.include?('LC_BUILD_VERSION') && command.match?(/^\s*platform\s+(?:MACOS|1)\s*$/)
        command[/^\s*minos\s+(\d+\.\d+(?:\.\d+)?)\s*$/,1]
      elsif command.include?('LC_VERSION_MIN_MACOSX')
        command[/^\s*version\s+(\d+\.\d+(?:\.\d+)?)\s*$/,1]
      end
    end
    versions.compact!
    raise 'Missing macOS deployment command' if versions.empty?
    versions.max_by { |version| version.split('.').map(&:to_i).values_at(0,1,2).map { |part| part || 0 } }
  end
  def self.minimum_macos_for_bundle(app, baseline:)
    raise 'Invalid application path' unless File.directory?(app) && !File.symlink?(app)
    versions = [baseline]
    magic = %w[feedface feedfacf cefaedfe cffaedfe cafebabe bebafeca cafebabf bfbafeca]
    Find.find(app) do |path|
      next unless File.lstat(path).file?
      header = File.open(path,'rb') { |file| file.read(4) }
      next unless header && magic.include?(header.unpack1('H*'))
      output,status = Open3.capture2e('/usr/bin/vtool','-show-build',path)
      raise 'Cannot inspect bundled deployment requirements' unless status.success?
      versions << minimum_macos_from_build_commands(output)
    end
    versions.max_by { |version| version.split('.').map(&:to_i).values_at(0,1,2).map { |part| part || 0 } }
  end
  def self.require_macos_compatibility!(minimum, target:)
    unless [minimum,target].all? { |value| value.is_a?(String) && value.match?(/\A[0-9]+(?:\.[0-9]+){1,2}\z/) }
      raise 'Invalid macOS deployment version'
    end
    raise "Requires macOS #{minimum}, above target #{target}" if Gem::Version.new(minimum) > Gem::Version.new(target)
    minimum
  end
  NOTICE = /\A(?:LICENSE|COPYING|COPYRIGHT|NOTICE|AUTHORS)/i
  def self.regular!(path)
    raise "Missing or linked material: #{File.basename(path)}" unless File.file?(path) && !File.symlink?(path)
    path
  end

  def self.material_path(root, relative)
    raise 'Material path escaped its root' unless relative.is_a?(String) && !relative.start_with?('/') && !relative.split('/').include?('..')
    path = regular!(File.join(root,relative))
    raise 'Linked material parent escaped its root' unless File.realpath(path).start_with?(root + '/')
    path
  end

  # Curated source-tree notices have frozen provenance but do not claim a
  # complete source offer or legal approval. No downloads or small-file hashes.
  def self.notice_inventory(directory)
    root = File.realpath(directory)
    report = JSON.parse(File.read(material_path(root,'SOURCES.json')))
    components = report.fetch('components')
    raise 'Invalid notice inventory' unless report['schema']==1 && components.is_a?(Array) && (1..100).cover?(components.length)
    names = components.map { |component| component.fetch('name') }
    raise 'Duplicate notice component' unless names.uniq.length == names.length
    count = 0
    components.each do |component|
      raise 'Unpinned notice provenance' unless component.fetch('commit').match?(/\A[0-9a-f]{40}\z/)
      notices = component.fetch('notices')
      raise 'Missing component notices' unless notices.is_a?(Array) && (1..256).cover?(notices.length)
      notices.each { |relative| material_path(root,relative) }
      count += notices.length
    end
    {'components'=>components.length,'notices'=>count,'legalReviewComplete'=>false}
  end

  def self.read_manifest(directory, verify_sources: true)
    root = File.realpath(directory)
    report = JSON.parse(File.read(regular!(File.join(root,'MATERIALS.json'))))
    raise 'Runtime materials are incomplete' unless report['schema']==1 && report['materialsComplete']==true
    files = ['MATERIALS.json']
    report.fetch('components').each do |component|
      prefix = component.fetch('directory')
      files.concat([File.join(prefix,'formula.rb'),File.join(prefix,'sbom.spdx.json')])
      component.fetch('notices').each { |name| files << File.join(prefix,'notices',name) }
      component.fetch('sources').each do |source|
        path = source.fetch('path')
        files << path
        archive = material_path(root,path)
        if source['gitRevision']
          raise 'Git source identity is missing' if verify_sources && !git_archive_identity(archive,source.fetch('url'),source.fetch('gitRevision'))
          files << path + '.identity.json'
        else
          raise 'Source identity changed before packaging' if verify_sources && Digest::SHA256.file(archive).hexdigest!=source.fetch('sha256')
        end
      end
    end
    files.each do |relative|
      material_path(root,relative)
    end
    [root,report,files.uniq]
  end

  def self.pack(directory, output)
    root, report, files = read_manifest(directory)
    output = File.expand_path(output)
    raise 'Archive must be outside its materials' if output.start_with?(root + '/') || File.symlink?(output)
    FileUtils.mkdir_p(File.dirname(output))
    _text, status = Open3.capture2e('/usr/bin/tar','-czf',output,'-C',root,'--null','-T','-',stdin_data:files.join("\0")+"\0")
    raise 'Runtime material packaging failed' unless status.success?
    {'components'=>report.fetch('components').length,'bytes'=>File.size(output),
      'sha256'=>Digest::SHA256.file(output).hexdigest,'legalReviewComplete'=>false}
  end

  def self.bundle_notices(directory, output)
    root, report, _files = read_manifest(directory,verify_sources:false)
    raise 'Linked notice bundle' if File.symlink?(output)
    FileUtils.mkdir_p(output)
    components = report.fetch('components').map do |component|
      name = component.fetch('name')
      raise 'Invalid component notice name' unless name.match?(/\A[a-z0-9][a-z0-9+@._-]*\z/)
      target = File.join(output,'licenses',name)
      raise 'Linked component notices' if File.symlink?(File.join(output,'licenses')) || File.symlink?(target)
      FileUtils.mkdir_p(target)
      component.fetch('notices').each do |notice|
        raise 'Invalid notice basename' unless File.basename(notice)==notice
        path = File.join(target,notice)
        raise 'Linked notice target' if File.symlink?(path)
        FileUtils.cp(regular!(File.join(root,component.fetch('directory'),'notices',notice)),path)
      end
      component.select { |key,_value| %w[name version license notices].include?(key) }
    end
    manifest = File.join(output,'SOURCE-MATERIALS.json')
    raise 'Linked bundle notice manifest' if File.symlink?(manifest)
    File.write(manifest,JSON.pretty_generate('schema'=>1,'components'=>components,'sourcePackageRequired'=>true,'legalReviewComplete'=>false)+"\n")
    {'components'=>components.length,'notices'=>components.sum { |component| component['notices'].length },'legalReviewComplete'=>false}
  end

  def self.collect(metadata:, cache:, destination:, fetch: false)
    cache = File.realpath(cache)
    destination = File.expand_path(destination)
    raise 'Linked materials destination' if File.symlink?(destination)
    raise 'Materials must be outside the bottle cache' if destination == cache || destination.start_with?(cache + '/')
    source = JSON.parse(File.read(regular!(metadata)))
    entries = source.fetch('formulae')
    raise 'Invalid formula inventory' unless entries.is_a?(Hash) && (1..100).cover?(entries.length)
    report = {'schema'=>1, 'scope'=>'frozen-runtime-source-materials', 'components'=>[],
      'missingSources'=>[], 'missingNotices'=>[], 'legalReviewComplete'=>false}
    FileUtils.mkdir_p(destination, mode: 0o700)
    manifest = File.join(destination,'MATERIALS.json')
    raise 'Linked materials report' if File.symlink?(manifest)
    File.write(manifest,JSON.pretty_generate(report.merge('materialsComplete'=>false))+"\n")
    entries.each do |name, information|
      raise 'Invalid formula name' unless name.match?(/\A[a-z0-9][a-z0-9+@._-]*\z/)
      roots = Dir.glob(File.join(cache,name,name,'*')).select { |path| File.directory?(path) }
      raise "Ambiguous or missing frozen bottle: #{name}" unless roots.length == 1
      root = File.realpath(roots.first)
      raise 'Bottle escaped cache' unless root.start_with?(cache + '/') && !File.symlink?(roots.first)
      sbom_file = regular!(File.join(root,'sbom.spdx.json'))
      sbom = JSON.parse(File.read(sbom_file))
      packages = sbom.fetch('packages')
      raise "Source version mismatch: #{name}" unless packages.first&.fetch('versionInfo',nil) == information.fetch('version')
      component = File.join(name,File.basename(root))
      target = File.join(destination,component)
      raise 'Linked component output' if File.symlink?(File.join(destination,name)) || File.symlink?(target)
      FileUtils.mkdir_p(File.join(target,'notices'))
      recipe = regular!(File.join(root,'.brew',name + '.rb'))
      FileUtils.cp(recipe,File.join(target,'formula.rb'))
      FileUtils.cp(sbom_file,File.join(target,'sbom.spdx.json'))
      notices = Dir.children(root).select { |item| item.match?(NOTICE) && File.file?(File.join(root,item)) }
      notices.each { |item| FileUtils.cp(regular!(File.join(root,item)),File.join(target,'notices',item)) }
      resources = packages.each_with_index.map do |package,index|
        uri = URI.parse(package.fetch('downloadLocation'))
        raise 'Source URL must be public HTTPS without credentials' unless uri.is_a?(URI::HTTPS) && uri.host && !uri.userinfo && !uri.fragment
        checksum = package.fetch('checksums').find { |value| value['algorithm']=='SHA256' }&.fetch('checksumValue',nil)
        if (checksum.nil? || checksum.empty?) && uri.path.end_with?('.git')
          revision = File.read(recipe).match(/url\s+"#{Regexp.escape(uri.to_s)}",\s*revision:\s*"([0-9a-f]{40})"/)&.captures&.first
          raise 'Git source has no frozen commit' unless revision
          relative = File.join(component,'sources',"#{index}-git-#{revision}.tar")
          archive = File.join(destination,relative)
          FileUtils.mkdir_p(File.dirname(archive))
          identity = git_archive_identity(archive,uri.to_s,revision)
          if fetch && !identity
            download_git(uri.to_s,revision,archive)
            identity = git_archive_identity(archive,uri.to_s,revision)
          end
          report['missingSources'] << relative unless identity
          next({'path'=>relative,'url'=>uri.to_s,'gitRevision'=>revision,'present'=>!identity.nil?,
            'verification'=>'checked-git-objects-and-local-archive-sha256','archiveSHA256'=>identity}.compact)
        end
        raise 'Source has no SHA256 identity' unless checksum&.match?(/\A[0-9a-f]{64}\z/)
        basename = File.basename(uri.path)
        raise 'Invalid source filename' unless basename.match?(/\A[a-zA-Z0-9][a-zA-Z0-9+._%-]*\z/)
        relative = File.join(component,'sources',"#{index}-#{basename}")
        archive = File.join(destination,relative)
        FileUtils.mkdir_p(File.dirname(archive))
        raise 'Linked source output' if File.symlink?(archive)
        download(uri.to_s,archive,checksum) if fetch && !File.file?(archive)
        present = File.file?(archive)
        raise "Source identity mismatch: #{name}" if present && Digest::SHA256.file(archive).hexdigest != checksum
        report['missingSources'] << relative unless present
        {'path'=>relative, 'url'=>uri.to_s, 'sha256'=>checksum, 'present'=>present}
      end
      # A top-level summary can refer to separate full license texts. Collect
      # source notices even when the bottle already supplied a LICENSE file.
      resources.select { |resource| resource['present'] }.each do |resource|
        notices.concat(extract_notices(File.join(destination,resource.fetch('path')),File.join(target,'notices')))
      end
      notices.uniq!
      report['missingNotices'] << name if notices.empty?
      report['components'] << {'name'=>name,'version'=>information.fetch('version'),'bottle'=>information.fetch('bottle'),
        'license'=>information['license'],'directory'=>component,'notices'=>notices,'sources'=>resources}
    end
    report['materialsComplete'] = report['missingSources'].empty? && report['missingNotices'].empty?
    File.write(manifest,JSON.pretty_generate(report)+"\n")
    report
  end

  def self.git_archive_identity(path, url, revision)
    return nil unless File.file?(path) && File.file?(path + '.identity.json')
    regular!(path); regular!(path + '.identity.json')
    identity = JSON.parse(File.read(path + '.identity.json'))
    raise 'Git source receipt mismatch' unless identity['url']==url && identity['gitRevision']==revision &&
      identity['archiveSHA256']&.match?(/\A[0-9a-f]{64}\z/) && Digest::SHA256.file(path).hexdigest==identity['archiveSHA256']
    identity['archiveSHA256']
  end

  def self.git_run(*arguments)
    environment = {'GIT_CONFIG_NOSYSTEM'=>'1','GIT_CONFIG_GLOBAL'=>File::NULL,'GIT_TERMINAL_PROMPT'=>'0'}
    pid = Process.spawn(environment,'/usr/bin/git','-c','core.hooksPath=/dev/null',
      '-c','http.lowSpeedLimit=1024','-c','http.lowSpeedTime=30',*arguments,
      pgroup:true,in:File::NULL,out:File::NULL,err:File::NULL)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC)+600
    loop do
      completed = Process.waitpid2(pid,Process::WNOHANG)
      if completed
        pid = nil
        raise 'Frozen Git source operation failed' unless completed.last.success?
        return
      end
      raise 'Frozen Git source operation timed out' if Process.clock_gettime(Process::CLOCK_MONOTONIC)>=deadline
      sleep 0.1
    end
  ensure
    if pid
      Process.kill('TERM',-pid) rescue nil
      sleep 0.2
      Process.kill('KILL',-pid) rescue nil
      Process.waitpid(pid) rescue nil
    end
  end

  def self.archive_git_repository(repository, revision, path)
    raise 'Invalid Git source commit' unless revision.match?(/\A[0-9a-f]{40}\z/)
    git_run('--git-dir',repository,'cat-file','-e',revision+'^{commit}')
    git_run('--git-dir',repository,'fsck','--full','--strict')
    git_run('--git-dir',repository,'update-ref','refs/heads/source',revision)
    git_run('--git-dir',repository,'symbolic-ref','HEAD','refs/heads/source')
    _text, status = Open3.capture2e('/usr/bin/tar','-cf',path,'-C',File.dirname(repository),File.basename(repository))
    raise 'Frozen Git source archive failed' unless status.success?
  end

  # Preserve a self-contained shallow Git repository, including its object
  # identities, rather than pretending a Git source has an upstream tar checksum.
  def self.download_git(url, revision, path)
    raise 'Linked Git source output' if File.symlink?(path) || File.symlink?(path + '.identity.json')
    temporary = path + ".download-#{Process.pid}"
    raise 'Linked Git download output' if File.symlink?(temporary)
    begin
      Dir.mktmpdir('mactv-source-git-',File.dirname(path)) do |directory|
        repository = File.join(directory,'source.git')
        git_run('init','--bare','--template=',repository)
        git_run('--git-dir',repository,'fetch','--depth=1',url,revision)
        archive_git_repository(repository,revision,temporary)
      end
      checksum = Digest::SHA256.file(temporary).hexdigest
      File.rename(temporary,path)
      File.write(path+'.identity.json',JSON.generate('url'=>url,'gitRevision'=>revision,'archiveSHA256'=>checksum)+"\n")
    ensure
      File.unlink(temporary) if File.file?(temporary)
    end
  end

  # Read recognized notices from verified archives to stdout, never unpack
  # paths or execute source. README license text and legacy full-license names
  # may live below the top level (for example docs/FTL.TXT or README.ijg).
  def self.extract_notices(archive, destination)
    listing, status = Open3.capture2e('/usr/bin/tar','-tf',archive)
    return [] unless status.success? && listing.bytesize <= 4_000_000
    members = listing.lines.map(&:strip).select do |member|
      parts = member.split('/').reject { |part| part == '.' }
      basename = parts.last.to_s
      notice = basename.match?(NOTICE) || basename.match?(/\A(?:FTL|(?:L?GPL)v?[0-9.]+)\.TXT\z/i)
      readme = basename.match?(/\AREADME(?:\.[A-Za-z0-9_-]+)?\z/i)
      spdx = parts.length >= 2 && parts[-2].casecmp('LICENSES').zero? &&
        basename.match?(/\A[A-Za-z0-9][A-Za-z0-9+._-]*\.(?:txt|md)\z/)
      !member.start_with?('/') && !parts.include?('..') && !member.end_with?('/') && (notice || readme || spdx)
    end
    raise 'Too many source notice candidates' if members.length > 512
    members.map do |member|
      content, result = Open3.capture2('/usr/bin/tar','-xOf',archive,member,err:File::NULL)
      next unless result.success? && !content.empty? && content.bytesize <= 1_048_576
      parts = member.split('/').reject { |part| part == '.' }
      basename = parts.last
      if basename.match?(/\AREADME(?:\.[A-Za-z0-9_-]+)?\z/i)
        next unless content.b.match?(/copyright|licen[sc]e|SPDX/in)
      end
      # Keep both the verified source object and the complete member path.
      # Flattening basenames loses nested or multi-root license identities.
      name = File.basename(archive) + '%2F' + parts.join('%2F')
      path = File.join(destination,name)
      raise 'Invalid source notice output' if name.bytesize > 240 || File.symlink?(path)
      File.binwrite(path,content)
      name
    end.compact
  end

  def self.download(url, path, checksum, headers: [])
    temporary = path + ".download-#{Process.pid}"
    raise 'Linked download output' if File.symlink?(temporary)
    begin
      _output, status = Open3.capture2e('/usr/bin/curl','-q','--fail','--location','--silent','--show-error',
        '--proto','=https','--proto-redir','=https','--connect-timeout','15','--max-time','600','--retry','2',
        *headers.flat_map { |value| ['--header',value] }, '--output',temporary,url)
      raise 'Upstream source download failed' unless status.success?
      raise 'Downloaded source identity mismatch' unless Digest::SHA256.file(temporary).hexdigest == checksum
      File.rename(temporary,path)
    ensure
      File.unlink(temporary) if File.file?(temporary)
    end
  end
end
