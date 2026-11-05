#!/usr/bin/env ruby
# Archive generated preview bundles only. Never touches the installed app,
# source, signing keys, account data, or arbitrary backup directories.
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'securerandom'

module PreviewArtifacts
  GROUPS = %w[dist/previous backups].freeze
  NAME = /\A(?:MacTV|MTV)-\d{8}-\d{6}-\d+\.app\z/
  def self.regular_directory!(path)
    raise 'Linked or missing directory' if File.symlink?(path) || !File.directory?(path)
  end
  def self.identity(path)
    contents = File.join(path,'Contents'); plist = File.join(contents,'Info.plist')
    return false unless File.directory?(contents) && !File.symlink?(contents) &&
      File.file?(plist) && !File.symlink?(plist) && File.size(plist) <= 65_536
    out, status = Open3.capture2e('/usr/libexec/PlistBuddy','-c','Print :CFBundleIdentifier',plist)
    status.success? && out.strip == 'local.mtv.preview'
  end
  def self.plan(root, keep: 3, identity: method(:identity), active: [])
    regular_directory!(root)
    raise 'Keep between 2 and 20 rollback copies' unless (2..20).cover?(keep)
    GROUPS.flat_map do |group|
      directory = File.join(root,group)
      next [] unless File.exist?(directory)
      regular_directory!(directory)
      # Check each intermediate directory rather than following a linked dist.
      cursor = directory
      until cursor == root
        regular_directory!(cursor); cursor = File.dirname(cursor)
      end
      entries = Dir.children(directory).select { |name| name.match?(NAME) }.map { |name| File.join(directory,name) }
        .reject { |path| File.symlink?(path) || !File.directory?(path) }
        .select { |path| identity.call(path) }
        .sort_by { |path| [File.mtime(path),File.basename(path)] }.reverse
      entries.drop(keep).reject { |path| active.any? { |executable| executable.start_with?(path + '/') } }
        .map { |path| {source:path,group:group,name:File.basename(path)} }
    end
  end
  def self.tree(path,timestamps: false)
    result = {}
    Find.find(path) do |entry|
      stat = File.lstat(entry)
      relative = entry.delete_prefix(path)
      raise 'Unsupported item in preview bundle' unless stat.file? || stat.directory? || stat.symlink?
      result[relative] = [stat.ftype,stat.file? ? stat.size : 0,stat.symlink? ? File.readlink(entry) : nil,stat.mode & 0o7777]
      result[relative] << stat.mtime if timestamps
    end
    result
  end
  def self.ditto(source, destination)
    _out, status = Open3.capture2e('/usr/bin/ditto','--rsrc','--extattr','--acl',source,destination)
    raise 'Preview archive copy failed; source retained' unless status.success?
  end
  def self.archive(entry, archive_root, copier: method(:ditto), before_remove: nil)
    source = entry.fetch(:source)
    raise 'Unexpected generated preview path' unless GROUPS.include?(entry.fetch(:group)) &&
      entry.fetch(:name).match?(NAME) && File.basename(source) == entry.fetch(:name) && identity(source)
    regular_directory!(source); regular_directory!(archive_root)
    parent = File.join(archive_root,entry.fetch(:group))
    # Never merge an archive with an existing destination or linked directory.
    cursor = archive_root
    entry.fetch(:group).split('/').each do |part|
      cursor = File.join(cursor,part)
      FileUtils.mkdir(cursor,mode:0o700) unless File.exist?(cursor) || File.symlink?(cursor)
      regular_directory!(cursor)
    end
    destination = File.join(parent,entry.fetch(:name))
    raise 'Archive destination exists; source retained' if File.exist?(destination) || File.symlink?(destination)
    original = File.stat(source)
    inventory = tree(source,timestamps:true)
    staged = destination + '.copying-' + SecureRandom.hex(6)
    begin
      copier.call(source,staged)
      regular_directory!(staged)
      raise 'Archive copy differs; source retained' unless tree(staged) == inventory.transform_values { |value| value.first(4) }
      before_remove&.call(source)
      now = File.stat(source)
      raise 'Preview changed while copying; source retained' unless [now.dev,now.ino,now.mtime] == [original.dev,original.ino,original.mtime] && tree(source,timestamps:true) == inventory
      File.rename(staged,destination)
      # A verified destination exists before the generated source is removed.
      FileUtils.remove_entry_secure(source)
      {name:entry.fetch(:name),group:entry.fetch(:group),files:inventory.length,
        bytes:inventory.values.sum { |value| value[1] }}
    ensure
      FileUtils.remove_entry_secure(staged) if File.directory?(staged) && !File.symlink?(staged)
    end
  end
  def self.external_archive!(root,path,create: true)
    path = File.expand_path(path)
    raise 'Archive cannot be inside the project' if path == root || path.start_with?(root + '/')
    cursor = path
    until File.exist?(cursor) || File.symlink?(cursor)
      parent = File.dirname(cursor); raise 'Archive volume is unavailable' if parent == cursor; cursor = parent
    end
    regular_directory!(cursor)
    raise 'Archive must be on a mounted external volume' if File.stat(cursor).dev == File.stat(root).dev
    # Refuse linked ancestors too; a missing mount must not become an internal folder.
    ancestor = cursor
    until ancestor == '/'
      regular_directory!(ancestor); ancestor = File.dirname(ancestor)
    end
    FileUtils.mkdir_p(path,mode:0o700) if create
    regular_directory!(path) if create || File.exist?(path)
    path
  end
end

if $PROGRAM_NAME == __FILE__
  root = File.expand_path('../..',__dir__)
  options = ARGV.dup
  configured = options.delete('--configured')
  configure = options.delete('--configure')
  apply = options.delete('--apply')
  disable = options.delete('--disable')
  argument = lambda do |name,default|
    index = options.index(name)
    index ? (raise 'Missing option value' unless options[index+1]; options.slice!(index,2).last) : default
  end
  archive = argument.call('--archive-root',nil)
  keep = Integer(argument.call('--keep','3'))
  limit = Integer(argument.call('--limit','12'))
  abort 'Unknown or conflicting preview archive arguments' unless options.empty? && (1..2000).cover?(limit) &&
    !(configure && configured) && !(disable && (configure || configured || apply || archive))
  config = File.join(root,'.build','preview-artifact-archive.json')
  begin
    FileUtils.mkdir_p(File.dirname(config))
    if disable
      raise 'Unsafe archive configuration' if File.symlink?(config) || (File.exist?(config) && (!File.file?(config) || File.stat(config).uid != Process.uid))
      File.unlink(config) if File.exist?(config)
      puts JSON.generate(schema:1,configured:false,archivesPreserved:true)
      exit 0
    end
    if configured
      exit 0 unless File.exist?(config)
      raise 'Unsafe archive configuration' unless File.file?(config) && !File.symlink?(config) && File.stat(config).uid == Process.uid
      value = JSON.parse(File.read(config)); raise 'Unsupported archive configuration' unless value['schema']==1; archive = value.fetch('archiveRoot'); keep = value.fetch('keep')
    end
    raise 'Supply --archive-root or configure preview storage first' unless archive
    archive = PreviewArtifacts.external_archive!(root,archive,create:!!(configure || apply))
    if configure
      raise 'Invalid rollback count' unless (2..20).cover?(keep)
      FileUtils.mkdir_p(File.dirname(config))
      File.write(config,JSON.pretty_generate(schema:1,archiveRoot:archive,keep:keep)+"\n",mode:'w',perm:0o600)
    end
    lock = File.open(File.join(root,'.build','preview-artifact-archive.lock'),File::RDWR|File::CREAT,0o600)
    unless lock.flock(File::LOCK_EX|File::LOCK_NB)
      if configured
        puts JSON.generate(schema:1,phase:'archive-already-active',sourceMediaModified:false)
        exit 0
      end
      raise 'Another preview archive is active'
    end
    processes, status = Open3.capture2('ps','-axo','comm=')
    raise 'Cannot observe active applications' unless status.success?
    entries = PreviewArtifacts.plan(root,keep:keep,active:processes.lines.map(&:strip))
    puts JSON.generate(schema:1,phase:'planned',eligible:entries.length,keepPerDirectory:keep,apply:!!apply)
    $stdout.flush
    moved = 0; bytes = 0
    if apply
      entries.first(limit).each do |entry|
        PreviewArtifacts.external_archive!(root,archive)
        result = PreviewArtifacts.archive(entry,archive)
        moved += 1; bytes += result[:bytes]
        puts JSON.generate(phase:'archived',index:moved,**result); $stdout.flush
      end
    end
    puts JSON.generate(schema:1,phase:'complete',moved:moved,bytes:bytes,remaining:entries.length-moved,sourceMediaModified:false)
  rescue StandardError => error
    warn JSON.generate(schema:1,phase:'failed',error:error.message,sourceMediaModified:false)
    exit 1
  end
end
