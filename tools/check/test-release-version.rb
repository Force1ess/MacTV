#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require_relative '../build/release-version'

class ReleaseVersionTest < Minitest::Test
  def test_stable_and_prerelease
    assert_equal({version: '1.0', bundle_version: '1.0', prerelease: false}, ReleaseVersion.parse('v1.0'))
    assert_equal({version: '1.0-rc.1', bundle_version: '1.0', prerelease: true}, ReleaseVersion.parse('v1.0-rc.1'))
    assert_equal({version: '1.2.3', bundle_version: '1.2.3', prerelease: false}, ReleaseVersion.parse('v1.2.3'))
    assert_equal({version: '1.2.3-beta.2', bundle_version: '1.2.3', prerelease: true}, ReleaseVersion.parse('v1.2.3-beta.2'))
  end
  def test_invalid_tags_are_rejected
    %w[v100 v1 v01.2.3 v1.2.3-01 v1.2.3+build main v1.2.3-].each do |tag|
      assert_raises(RuntimeError) { ReleaseVersion.parse(tag) }
    end
  end
  def test_stamps_only_the_staged_plist
    Dir.mktmpdir do |root|
      source = File.expand_path('../../config/Info.plist', __dir__)
      original = File.binread(source)
      staged = File.join(root, 'Info.plist')
      File.binwrite(staged, original)
      ReleaseVersion.stamp(staged, 'v1.2.3-beta.2', '123')
      assert_equal original, File.binread(source)
      {'CFBundleShortVersionString'=>'1.2.3', 'CFBundleVersion'=>'123', 'MacTVReleaseVersion'=>'1.2.3-beta.2'}.each do |key, expected|
        actual, status = Open3.capture2e('/usr/libexec/PlistBuddy', '-c', "Print :#{key}", staged)
        assert status.success?
        assert_equal expected, actual.strip
      end
      assert_raises(RuntimeError) { ReleaseVersion.stamp(staged, 'v1.2.3', '0') }
    end
  end
end
