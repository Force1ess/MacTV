#!/usr/bin/env ruby
require 'tmpdir'
require_relative '../build/native-runtime-materials'
require_relative '../build/rebuild-native-mpv'

checks = {}
def rejects
  yield
  false
rescue StandardError
  true
end
Dir.mktmpdir('mactv-frozen-linker-') do |directory|
  cache = File.join(directory,'cache'); root = File.join(cache,'owned/owned/1.0')
  staged = File.join(directory,'runtime'); pc = File.join(directory,'pkgconfig'); sdk = File.join(directory,'sdk')
  FileUtils.mkdir_p([File.join(root,'lib/pkgconfig'),File.join(staged,'lib'),pc,File.join(sdk,'usr/include')])
  File.write(File.join(root,'lib/libowned.1.dylib'),'Owned library identity fixture')
  File.symlink('libowned.1.dylib',File.join(root,'lib/libowned.dylib'))
  File.write(File.join(staged,'lib/libowned.1.dylib'),'Owned library identity fixture')
  File.write(File.join(root,'lib/pkgconfig/owned.pc'),"prefix=@@HOMEBREW_CELLAR@@/owned/1.0\nlibdir=${prefix}/lib\nincludedir=${prefix}/include/nested\nName: Owned\nVersion: 1.0\nLibs: -L${libdir} -lowned\nCflags: -I${includedir}\n")
  File.write(File.join(sdk,'usr/include/zlib.h'), '#define ZLIB_VERSION "1.2.3"')
  File.write(File.join(sdk,'usr/include/bzlib.h'), 'bzip2/libbzip2 version 1.0.8')
  inventory = {'components'=>[{'name'=>'owned','directory'=>'owned/1.0'}]}
  generate = -> { RebuildNativeMPV.pkgconfig(inventory,cache,staged,pc,directory,sdk:sdk) }
  generate.call
  alias_path = File.join(directory,'link-libraries/libowned.dylib')
  checks['frozenSourceBuildCreatesOnlyWorkspaceLinkerAliases'] = File.symlink?(alias_path) && File.realpath(alias_path) == File.realpath(File.join(staged,'lib/libowned.1.dylib'))
  checks['frozenSourceBuildPreservesNestedHeaderDirectory'] = File.read(File.join(pc,'owned.pc')).include?('includedir=${prefix}/include/nested')
  checks['frozenSourceBuildReadsActualSDKHeaderVersions'] = File.read(File.join(pc,'zlib.pc')).include?('Version: 1.2.3') && File.read(File.join(pc,'bzip2.pc')).include?('Version: 1.0.8')
  inventory['components'][0]['directory']='owned/../escape'
  checks['frozenSourceBuildRejectsEscapingHeaderRoot'] = rejects { generate.call }
end
Dir.mktmpdir('mactv-notice-inventory-') do |directory|
  File.write(File.join(directory,'LICENSE.txt'),'Owned notice fixture')
  manifest = {'schema'=>1,'components'=>[{'name'=>'owned','commit'=>'1'*40,'notices'=>['LICENSE.txt']}]}
  write = -> { File.write(File.join(directory,'SOURCES.json'),JSON.generate(manifest)) }
  write.call
  checks['noticeInventoryReadsFrozenPlainNotices'] = NativeRuntimeMaterials.notice_inventory(directory)['notices']==1
  manifest['components'][0]['commit']='main'; write.call
  checks['noticeInventoryRejectsMovingRevision'] = rejects { NativeRuntimeMaterials.notice_inventory(directory) }
  manifest['components'][0]['commit']='1'*40
  manifest['components'][0]['notices']=['../LICENSE.txt']; write.call
  checks['noticeInventoryRejectsEscapingPath'] = rejects { NativeRuntimeMaterials.notice_inventory(directory) }
  manifest['components'][0]['notices']=['missing.txt']; write.call
  checks['noticeInventoryRejectsMissingDeclaredFile'] = rejects { NativeRuntimeMaterials.notice_inventory(directory) }
  manifest['components'][0]['notices']=['LICENSE.txt']
  manifest['components'] << manifest['components'][0].dup; write.call
  checks['noticeInventoryRejectsDuplicateComponents'] = rejects { NativeRuntimeMaterials.notice_inventory(directory) }
end
Dir.mktmpdir('mactv-runtime-materials-') do |directory|
  cache = File.join(directory,'bottles')
  root = File.join(cache,'owned','owned','1.0_1')
  FileUtils.mkdir_p(File.join(root,'.brew'))
  File.write(File.join(root,'.brew','owned.rb'),'raise "Formulae must not be evaluated"')
  File.write(File.join(root,'COPYING'),'Owned test notice')
  data = 'Owned source fixture'
  package = {'versionInfo'=>'1.0','downloadLocation'=>'https://example.com/owned-1.0.tar.gz',
    'checksums'=>[{'algorithm'=>'SHA256','checksumValue'=>Digest::SHA256.hexdigest(data)}]}
  sbom = File.join(root,'sbom.spdx.json')
  File.write(sbom,JSON.generate('packages'=>[package]))
  metadata = File.join(directory,'SOURCE.json')
  File.write(metadata,JSON.generate('formulae'=>{'owned'=>{'version'=>'1.0','license'=>'MIT',
    'bottle'=>{'url'=>'https://example.com/frozen-bottle'}}}))
  output = File.join(directory,'materials')
  collect = -> { NativeRuntimeMaterials.collect(cache:cache,metadata:metadata,destination:output) }
  report = collect.call
  checks['missingSourceIsNotReportedComplete'] = !report['materialsComplete'] && report['missingSources'].length == 1
  checks['rootNoticeAndFrozenRecipeRetainedWithoutExecuting'] =
    File.read(File.join(output,'owned/1.0_1/notices/COPYING')) == 'Owned test notice' &&
    File.read(File.join(output,'owned/1.0_1/formula.rb')).include?('must not be evaluated')
  archive = File.join(output,report['missingSources'].first)
  File.write(archive,data)
  report = collect.call
  checks['matchingSourceIdentityAllowsMaterialsCompletion'] = report['materialsComplete'] && !report['legalReviewComplete']
  bundle = File.join(directory,'notice-bundle')
  notice_report = NativeRuntimeMaterials.bundle_notices(output,bundle)
  checks['noticeBundleKeepsSourcePackageAndReviewBoundary'] = notice_report['components']==1 &&
    JSON.parse(File.read(File.join(bundle,'SOURCE-MATERIALS.json')))['sourcePackageRequired']==true &&
    File.read(File.join(bundle,'licenses/owned/COPYING')) == 'Owned test notice'
  File.write(File.join(output,'unrelated-private-fixture'),'Not part of the source package')
  packed = File.join(directory,'materials.tar.gz')
  NativeRuntimeMaterials.pack(output,packed)
  listing, packed_status = Open3.capture2('/usr/bin/tar','-tf',packed)
  checks['sourcePackageContainsOnlyDeclaredMaterials'] = packed_status.success? &&
    listing.include?('MATERIALS.json') && listing.include?('owned/1.0_1/sources/') &&
    !listing.include?('unrelated-private-fixture')
  File.write(archive,'corrupt')
  checks['corruptSourceRejectedAndPriorReportInvalidated'] = rejects { collect.call } &&
    JSON.parse(File.read(File.join(output,'MATERIALS.json')))['materialsComplete'] == false
  File.write(archive,data)
  package['versionInfo'] = '2.0'; File.write(sbom,JSON.generate('packages'=>[package]))
  checks['differentSourceVersionRejected'] = rejects { collect.call }
  package['versionInfo'] = '1.0'
  package['downloadLocation'] = 'https://private:secret@example.com/source.tar.gz'
  File.write(sbom,JSON.generate('packages'=>[package]))
  checks['credentialBearingSourceURLRejected'] = rejects { collect.call }
  package['downloadLocation'] = 'https://example.com/owned-1.0.tar.gz'
  File.write(sbom,JSON.generate('packages'=>[package]))
  File.unlink(File.join(root,'COPYING')); File.symlink(metadata,File.join(root,'COPYING'))
  checks['linkedNoticeRejected'] = rejects { collect.call }
  File.unlink(File.join(root,'COPYING'))
  source_tree = File.join(directory,'owned-source')
  FileUtils.mkdir_p(source_tree)
  File.write(File.join(source_tree,'COPYING'),'Notice from verified source')
  FileUtils.mkdir_p(File.join(source_tree,'LICENSES'))
  File.write(File.join(source_tree,'LICENSES','MIT.txt'),'Owned SPDX license text')
  _text, status = Open3.capture2e('/usr/bin/tar','-cf',archive,'-C',directory,'owned-source')
  raise 'Owned archive fixture failed' unless status.success?
  package['checksums'][0]['checksumValue'] = Digest::SHA256.file(archive).hexdigest
  File.write(sbom,JSON.generate('packages'=>[package]))
  report = collect.call
  checks['missingBottleNoticeRecoveredFromVerifiedArchive'] = report['materialsComplete'] &&
    report['components'][0]['notices'].any? { |name|
      File.read(File.join(output,'owned/1.0_1/notices',name)) == 'Notice from verified source'
    }
  checks['spdxLicenseDirectoryRetained'] = report['components'][0]['notices'].any? { |name| File.read(File.join(output,'owned/1.0_1/notices',name)) == 'Owned SPDX license text' }
  # A present bottle summary must not suppress nested full license text.
  File.write(File.join(root,'LICENSE.TXT'),'See docs/FTL.TXT for full terms')
  FileUtils.mkdir_p(File.join(source_tree,'docs'))
  File.write(File.join(source_tree,'docs/FTL.TXT'),'Owned complete font license')
  File.write(File.join(source_tree,'README.ijg'),'Owned JPEG copyright and license')
  _text,status = Open3.capture2e('/usr/bin/tar','-cf',archive,'-C',directory,'owned-source')
  raise 'Nested license fixture failed' unless status.success?
  package['checksums'][0]['checksumValue'] = Digest::SHA256.file(archive).hexdigest
  File.write(sbom,JSON.generate('packages'=>[package]))
  report=collect.call
  checks['existingSummaryDoesNotSuppressNestedFullLicense'] =
    report['components'][0]['notices'].any? { |name| File.read(File.join(output,'owned/1.0_1/notices',name)) == 'Owned complete font license' }
  checks['jpegReadmeLicenseIsRetained'] =
    report['components'][0]['notices'].any? { |name| File.read(File.join(output,'owned/1.0_1/notices',name)) == 'Owned JPEG copyright and license' }
  FileUtils.mkdir_p(File.join(source_tree,'nested-one'))
  FileUtils.mkdir_p(File.join(source_tree,'nested-two'))
  File.write(File.join(source_tree,'nested-one/COPYING'),'Owned first nested license')
  File.write(File.join(source_tree,'nested-two/COPYING'),'Owned second nested license')
  legacy_bytes="Copyright owned legacy notice ".b + [0xe9].pack('C')
  File.binwrite(File.join(source_tree,'README.legacy'),legacy_bytes)
  _text,status=Open3.capture2e('/usr/bin/tar','-cf',archive,'-C',directory,'owned-source')
  raise 'Distinct source notice fixture failed' unless status.success?
  package['checksums'][0]['checksumValue']=Digest::SHA256.file(archive).hexdigest
  File.write(sbom,JSON.generate('packages'=>[package])); report=collect.call
  notice_bytes=report['components'][0]['notices'].map { |name| File.binread(File.join(output,'owned/1.0_1/notices',name)) }
  checks['nestedNoticesWithSameBasenameRemainDistinct']=notice_bytes.include?('Owned first nested license') && notice_bytes.include?('Owned second nested license')
  checks['legacyEncodingLicenseBytesArePreserved']=notice_bytes.include?(legacy_bytes)
  revision = 'a' * 40
  package['downloadLocation'] = 'https://example.com/owned.git'
  package['checksums'][0]['checksumValue'] = ''
  File.write(sbom,JSON.generate('packages'=>[package]))
  File.write(File.join(root,'.brew','owned.rb'),"url \"https://example.com/owned.git\", revision: \"#{revision}\"")
  report = collect.call
  checks['pinnedGitSourceRemainsExplicitlyIncomplete'] = !report['materialsComplete'] &&
    report['components'][0]['sources'][0]['gitRevision'] == revision && report['missingSources'].length == 1
  worktree = File.join(directory,'git-worktree')
  NativeRuntimeMaterials.git_run('init','--template=',worktree)
  File.write(File.join(worktree,'README'),'Owned source tree')
  NativeRuntimeMaterials.git_run('-C',worktree,'add','README')
  NativeRuntimeMaterials.git_run('-C',worktree,'-c','user.name=Owned Fixture','-c','user.email=fixture@example.com',
    'commit','-m','Owned source')
  revision, status = Open3.capture2('/usr/bin/git','-C',worktree,'rev-parse','HEAD')
  raise 'Owned commit fixture failed' unless status.success?
  revision = revision.strip
  repository = File.join(directory,'source.git')
  NativeRuntimeMaterials.git_run('clone','--bare','--no-hardlinks',worktree,repository)
  git_archive = File.join(directory,'owned-git.tar')
  NativeRuntimeMaterials.archive_git_repository(repository,revision,git_archive)
  listing, status = Open3.capture2('/usr/bin/tar','-tf',git_archive)
  checks['gitSnapshotRetainsIndependentRepositoryObjects'] = status.success? &&
    listing.include?('source.git/HEAD') && listing.include?('source.git/objects/')
  checksum = Digest::SHA256.file(git_archive).hexdigest
  File.write(git_archive+'.identity.json',JSON.generate('url'=>'https://example.com/owned.git',
    'gitRevision'=>revision,'archiveSHA256'=>checksum))
  checks['gitArchiveReceiptDistinguishesCommitAndArchiveIdentity'] =
    NativeRuntimeMaterials.git_archive_identity(git_archive,'https://example.com/owned.git',revision) == checksum
  File.write(git_archive,'corrupt')
  checks['changedGitArchiveRejected'] = rejects {
    NativeRuntimeMaterials.git_archive_identity(git_archive,'https://example.com/owned.git',revision)
  }
end
checks['deploymentMinimumIsNotTheSDKVersion'] = NativeRuntimeMaterials.minimum_macos_from_build_commands("Load command 1\n cmd LC_BUILD_VERSION\n platform MACOS\n minos 15.0\n sdk 26.3\n") == '15.0'
checks['mixedArchitecturesUseHighestMacOSMinimum'] = NativeRuntimeMaterials.minimum_macos_from_build_commands("Load command 1\n cmd LC_BUILD_VERSION\n platform MACOS\n minos 15.0\nLoad command 2\n cmd LC_BUILD_VERSION\n platform MACOS\n minos 26.0\n sdk 26.5\n") == '26.0'
checks['olderDependenciesFitTheApplicationTarget'] = NativeRuntimeMaterials.require_macos_compatibility!('12.0',target:'15.0') == '12.0'
checks['newerDependencyCannotSilentlyRaiseTheApplicationTarget'] = rejects { NativeRuntimeMaterials.require_macos_compatibility!('26.0',target:'15.0') }
checks['malformedDeploymentTargetIsRejected'] = rejects { NativeRuntimeMaterials.require_macos_compatibility!('15.0',target:'15.0; echo invalid') }
checks['foreignPlatformCannotMasqueradeAsMacOS'] = rejects { NativeRuntimeMaterials.minimum_macos_from_build_commands("Load command 1\n cmd LC_BUILD_VERSION\n platform IOS\n minos 17.0\n sdk 26.0\n") }
puts JSON.pretty_generate('scope'=>'owned-runtime-material-fixtures','checks'=>checks,'passed'=>checks.values.all?,'networkUsed'=>false)
exit(checks.values.all? ? 0:1)
