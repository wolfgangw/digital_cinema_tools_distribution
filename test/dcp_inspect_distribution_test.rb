# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../scripts/dcp-inspect-release'

class DcpInspectDistributionTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  BUNDLE = File.join(ROOT, 'vendor/dcp_inspect')

  def run!(*args, **options)
    output, error, status = Open3.capture3(*args, **options)
    assert status.success?, "#{args.inspect}: #{output}#{error}"
    output
  end

  def test_release_and_relocated_command_symlink
    metadata = DcpInspectRelease.verify(BUNDLE)
    Dir.mktmpdir('dct install with spaces ') do |directory|
      checkout = File.join(directory, 'distribution')
      FileUtils.mkdir_p(checkout)
      FileUtils.cp(File.join(ROOT, 'dcp_inspect'), checkout)
      FileUtils.cp_r(File.join(ROOT, 'vendor'), checkout)
      command = File.join(directory, 'dcp_inspect')
      File.symlink(File.join(checkout, 'dcp_inspect'), command)
      output = run!(RbConfig.ruby, command, '--version', chdir: '/')
      assert_includes output, "v#{metadata.fetch('version')}"
      assert_includes run!(RbConfig.ruby, command, '--help', chdir: '/'), '--tfs'
      schemas = <<~'CODE'
        require 'dcp_inspect'
        store = DcpInspect::XML::SchemaStore.new
        %w[PROTO-ASDCP-AM-20040311.xsd PROTO-ASDCP-PKL-20040311.xsd PROTO-ASDCP-CPL-20040511.xsd SMPTE-429-9-2007-AM.xsd SMPTE-429-8-2006-PKL.xsd SMPTE-429-7-2006-CPL.xsd DCDMSubtitle-2010.xsd].each { |name| store.schema(name) }
      CODE
      run!(RbConfig.ruby, '-I', File.join(checkout, 'vendor/dcp_inspect/lib'), '-e', schemas, chdir: '/')
    end
  end

  def test_modified_missing_and_extra_files_are_rejected
    Dir.mktmpdir do |directory|
      copy = File.join(directory, 'bundle')
      FileUtils.cp_r(BUNDLE, copy)
      File.write(File.join(copy, 'VERSION'), 'broken')
      assert_raises(RuntimeError) { DcpInspectRelease.verify(copy) }
      FileUtils.cp(File.join(BUNDLE, 'VERSION'), copy)
      File.write(File.join(copy, 'unexpected'), 'extra')
      assert_raises(RuntimeError) { DcpInspectRelease.verify(copy) }
      File.delete(File.join(copy, 'unexpected'))
      File.delete(File.join(copy, 'xsd/catalog.xml'))
      assert_raises(RuntimeError) { DcpInspectRelease.verify(copy) }
    end
  end

  def test_reproducible_export_dirty_source_rejection_and_invalid_release_rollback
    Dir.mktmpdir('dct release ') do |directory|
      source = File.join(directory, 'source')
      destination = File.join(directory, 'distribution')
      FileUtils.cp_r(BUNDLE, source)
      FileUtils.mkdir_p(destination)
      FileUtils.cp_r(File.join(ROOT, 'scripts'), destination)
      run!('git', 'init', '-q', source)
      run!('git', '-C', source, 'add', '.')
      commit = -> { run!('git', '-C', source, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'fixture') }
      commit.call
      updater = File.join(destination, 'scripts/update-dcp-inspect.rb')
      exported = File.join(destination, 'vendor/dcp_inspect')
      run!(RbConfig.ruby, updater, source)
      first = File.read(File.join(exported, 'RELEASE.json'))
      File.write(File.join(exported, 'stale-file'), 'remove on next export')
      run!(RbConfig.ruby, updater, source)
      assert_equal first, File.read(File.join(exported, 'RELEASE.json'))
      refute File.exist?(File.join(exported, 'stale-file'))
      File.write(File.join(source, 'VERSION'), "invalid\n")
      _, error, status = Open3.capture3(RbConfig.ruby, updater, source)
      refute status.success?
      assert_includes error, 'Commit or stash'
      assert_equal first, File.read(File.join(exported, 'RELEASE.json'))
      # A committed incomplete release must not replace the working bundle.
      run!('git', '-C', source, 'rm', 'xsd/catalog.xml')
      commit.call
      run!('git', '-C', source, 'restore', 'VERSION')
      _, error, status = Open3.capture3(RbConfig.ruby, updater, source)
      refute status.success?
      assert_includes error, 'Missing release file'
      assert_equal first, File.read(File.join(exported, 'RELEASE.json'))
      DcpInspectRelease.verify(exported)
    end
  end

  def test_gem_install_failure_is_not_reported_as_success
    Dir.mktmpdir do |directory|
      gem = File.join(directory, 'gem')
      File.write(gem, "#!/bin/sh\nexit 1\n")
      File.chmod(0o755, gem)
      output, _, status = Open3.capture3({'PATH' => "#{directory}:#{ENV.fetch('PATH')}"}, 'bash', File.join(ROOT, 'scripts/install-dcp-inspect-dependencies.sh'))
      refute status.success?
      refute_includes output, 'Installed gem'
    end
  end
  def test_dependency_helper_installs_missing_gems_and_propagates_rehash_failure
    Dir.mktmpdir do |directory|
      scripts = {
        'gem' => "#!/bin/sh\n[ \"$1\" = list ] && exit 1\nexit 0\n",
        'rbenv' => "#!/bin/sh\nexit 0\n",
        'ruby' => "#!/bin/sh\nexit 0\n"
      }
      scripts.each do |name, content|
        File.write(File.join(directory, name), content)
        File.chmod(0o755, File.join(directory, name))
      end
      environment = {'PATH' => "#{directory}:#{ENV.fetch('PATH')}"}
      helper = File.join(ROOT, 'scripts/install-dcp-inspect-dependencies.sh')
      output = run!(environment, 'bash', helper)
      %w[nokogiri ttfunk base64].each { |name| assert_includes output, "Installed gem #{name}" }
      File.write(File.join(directory, 'rbenv'), "#!/bin/sh\nexit 1\n")
      _, _, status = Open3.capture3(environment, 'bash', helper)
      refute status.success?
    end
  end

  def test_runtime_verifier_rejects_missing_audio_filters
    Dir.mktmpdir do |directory|
      %w[asdcp-info asdcp-unwrap ffmpeg mkfifo].each do |name|
        path = File.join(directory, name)
        File.write(path, "#!/bin/sh\nexit 0\n")
        File.chmod(0o755, path)
      end
      _, error, status = Open3.capture3({'PATH' => "#{directory}:#{ENV.fetch('PATH')}"},
                                       RbConfig.ruby, File.join(ROOT, 'scripts/verify-dcp-inspect.rb'), '--runtime')
      refute status.success?
      assert_includes error, 'Required FFmpeg filter missing'
    end
  end

end
