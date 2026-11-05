#!/usr/bin/env ruby
require 'tmpdir'
require_relative '../build/preview-artifacts'

def app(root, name, identity='local.mtv.preview')
  path=File.join(root,'dist/previous',name)
  FileUtils.mkdir_p(File.join(path,'Contents/MacOS'))
  File.write(File.join(path,'Contents/Info.plist'),"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>#{identity}</string></dict></plist>")
  File.write(File.join(path,'Contents/MacOS/MTV'),'owned binary fixture')
  File.symlink('MTV',File.join(path,'Contents/MacOS/Alias'))
  path
end

def rejects
  begin; yield; false; rescue StandardError; true; end
end
checks={}
Dir.mktmpdir('mactv-preview-storage-') do |root|
  archive=File.join(root,'archive'); FileUtils.mkdir(archive)
  names=(1..5).map { |n| "MacTV-20261101-12000#{n}-#{n}.app" }
  paths=names.map { |name| app(root,name) }
  paths.each_with_index { |path,index| File.utime(Time.at(index+100),Time.at(index+100),path) }
  other=app(root,'MacTV-20261101-120006-6.app','dev.other')
  File.utime(Time.at(1000),Time.at(1000),other)
  unknown=File.join(root,'dist/previous','MacTV-20261101-120007-7.app')
  FileUtils.mkdir_p(File.join(unknown,'Contents'))
  entries=PreviewArtifacts.plan(root,keep:2)
  checks['identityInspectionDoesNotCreateMissingMetadata'] = !File.exist?(File.join(unknown,'Contents/Info.plist'))
  checks['onlyGeneratedPreviewIdentityAndRecentRollbackCopies'] = entries.map { |e| e[:name] }.sort==names.first(3).sort
  checks['activeOlderBundleIsNeverArchived'] = !PreviewArtifacts.plan(root,keep:2,active:[File.join(paths[0],'Contents/MacOS/MTV')]).any? { |e|e[:source]==paths[0] }
  entry=entries.find { |e|e[:name]==names[0] }
  before=PreviewArtifacts.tree(entry[:source])
  result=PreviewArtifacts.archive(entry,archive)
  destination=File.join(archive,entry[:group],entry[:name])
  checks['verifiedCopyPreservesBundleAndInternalLinkBeforeRemovingSource'] = !File.exist?(entry[:source]) && PreviewArtifacts.tree(destination)==before && result[:bytes]>0
  entry=entries.find { |e|e[:name]==names[1] }
  parent=File.join(archive,entry[:group]); FileUtils.mkdir_p(parent)
  File.write(File.join(parent,entry[:name]),'existing archive')
  checks['existingDestinationCannotOverwriteOrRemoveSource'] = rejects { PreviewArtifacts.archive(entry,archive) } && File.directory?(entry[:source])
  File.unlink(File.join(parent,entry[:name]))
  checks['failedCopyPreservesSource'] = rejects { PreviewArtifacts.archive(entry,archive,copier:->(_a,_b){ raise 'owned copy failure' }) } && File.directory?(entry[:source])
  checks['differentCopyPreservesSource'] = rejects { PreviewArtifacts.archive(entry,archive,copier:->(a,b){ FileUtils.cp_r(a,b); File.write(File.join(b,'added'),'changed') }) } && File.directory?(entry[:source])
  checks['sameSizeSourceEditDuringCopyPreservesSource'] = rejects { PreviewArtifacts.archive(entry,archive,before_remove:->(a){File.write(File.join(a,'Contents/MacOS/MTV'),'OWNED binary fixture')}) } && File.directory?(entry[:source])
  linked=File.join(root,'linked'); File.symlink(archive,linked)
  checks['linkedArchiveIsRejected'] = rejects { PreviewArtifacts.archive(entry,linked) }
  missing=File.join(root,'unmounted-volume','archive')
  checks['unmountedExternalArchiveCannotConsumeSystemDisk'] = rejects { PreviewArtifacts.external_archive!(root,missing) } && !File.exist?(missing)
end
puts JSON.pretty_generate(scope:'owned-preview-storage-fixtures',checks:checks,passed:checks.values.all?)
exit(checks.values.all? ? 0:1)
