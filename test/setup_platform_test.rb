# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'json'

class SetupPlatformTest < Minitest::Test
  SETUP = File.expand_path('../digital-cinema-tools-setup', __dir__)

  def shell(code, *arguments, environment: {})
    Open3.capture3(environment, 'bash', '-c', 'source "$1"; shift; ' + code, 'test', SETUP, *arguments)
  end

  def test_os_release_detection
    {'omarchy' => ['arch', 'omarchy'], 'arch' => ['', 'arch'],
     'arch-derivative' => ['arch linux', 'arch'], 'ubuntu' => ['debian', 'ubuntu'],
     'debian' => ['', 'debian'], 'linuxmint' => ['ubuntu debian', 'ubuntu'],
     'fedora' => ['', 'redhat']}.each do |id, (like, expected)|
      Dir.mktmpdir do |directory|
        release = File.join(directory, 'os-release')
        File.write(release, "ID=#{id}\nID_LIKE=\"#{like}\"\n")
        output, error, status = shell('dct_detect_linux "$1"', release)
        assert status.success?, error
        assert_equal expected, output.strip
      end
    end
  end

  def test_unknown_distribution_is_not_silently_treated_as_arch
    Dir.mktmpdir do |directory|
      release = File.join(directory, 'os-release')
      File.write(release, "ID=unknown\n")
      _, _, status = shell('dct_detect_linux "$1"', release)
      refute status.success?
    end
  end

  def test_native_arch_dependency_names
    output, _, status = shell('dct_arch_packages')
    assert status.success?
    %w[base-devel mise xerces-c xmlsec fd ffmpeg util-linux].each { |name| assert_includes output.split, name }
    refute output.split.any? { |name| name.end_with?('-dev', '-devel') && name != 'base-devel' }
  end

  def test_package_install_uses_omarchy_helper_or_pacman_without_refresh
    Dir.mktmpdir do |directory|
      log = File.join(directory, 'commands')
      code = <<~'SH'
        omarchy() { echo "omarchy $*" >> "$DCT_TEST_LOG"; }
        sudo() { echo "sudo $*" >> "$DCT_TEST_LOG"; }
        pacman() { echo "pacman $*" >> "$DCT_TEST_LOG"; }
        dct_install_arch_packages "$1" ruby-build xerces-c
      SH
      %w[omarchy arch].each do |platform|
        File.write(log, '')
        _, error, status = shell(code, platform, environment: {'DCT_TEST_LOG' => log})
        assert status.success?, error
        calls = File.read(log)
        assert_includes calls, platform == 'omarchy' ? 'omarchy pkg add ruby-build xerces-c' : 'sudo pacman -S --needed ruby-build xerces-c'
        assert_includes calls, 'pacman -Q ruby-build'
        refute_includes calls, '-Sy'
        refute_includes calls, '--noconfirm'
      end
    end
  end

  def test_package_failure_and_missing_post_install_package_propagate
    ['sudo() { return 1; }; pacman() { return 0; }',
     'sudo() { return 0; }; pacman() { return 1; }'].each do |mocks|
      _, _, status = shell(mocks + '; dct_install_arch_packages arch ruby-build')
      refute status.success?
    end
  end

  def test_launcher_pins_ruby_preserves_arguments_and_does_not_modify_source
    Dir.mktmpdir('dct launcher ') do |directory|
      program = File.join(directory, 'source.rb')
      command = File.join(directory, 'command')
      code = "require 'json'; puts JSON.generate([RUBY_VERSION, ARGV, ENV.values_at('GEM_HOME', 'GEM_PATH', 'RUBYOPT', 'RUBYLIB')])\n"
      File.write(program, code)
      File.symlink(program, command)
      gems = File.join(directory, 'tool gems')
      FileUtils.mkdir_p(gems)
      _, error, status = shell('dct_write_ruby_launcher "$1" "$2" "$3" "$4"', RbConfig.ruby, program, command, gems)
      assert status.success?, error
      output, error, status = Open3.capture3({'GEM_HOME' => '/missing', 'GEM_PATH' => '/missing', 'RUBYOPT' => '-rmissing', 'RUBYLIB' => '/missing'}, command, 'with spaces', '$(literal)', '')
      assert status.success?, error
      assert_equal [RUBY_VERSION, ['with spaces', '$(literal)', ''], [gems, gems, nil, nil]], JSON.parse(output)
      assert_equal code, File.read(program)
      _, _, status = shell('dct_write_ruby_launcher "$1" "$2" "$3" "$4"', RbConfig.ruby, program, command, gems)
      assert status.success?, 'Managed launchers must be updatable'
      File.write(command, 'user owned file')
      _, _, status = shell('dct_write_ruby_launcher "$1" "$2" "$3" "$4"', RbConfig.ruby, program, command, gems)
      refute status.success?
      assert_equal 'user owned file', File.read(command)
    end
  end

  def test_mise_ruby_reuses_installed_runtime_without_install_or_global_changes
    prefix = File.dirname(File.dirname(RbConfig.ruby))
    code = 'mise() { [[ $1 == where ]] || return 99; printf "%s\n" "$DCT_TEST_RUBY"; }; dct_prepare_mise_ruby "$1"'
    output, error, status = shell(code, RUBY_VERSION, environment: {'DCT_TEST_RUBY' => prefix})
    assert status.success?, error
    assert_equal prefix, output.strip
  end

  def test_mise_download_requests_prebuilt_only_and_does_not_activate_ruby
    Dir.mktmpdir do |directory|
      marker = File.join(directory, 'installed')
      prefix = File.dirname(File.dirname(RbConfig.ruby))
      code = <<~'SH'
        mise() {
          case "$1" in
            where) [[ -f "$DCT_TEST_MARKER" ]] || return 1; printf '%s\n' "$DCT_TEST_RUBY" ;;
            install) [[ $MISE_RUBY_COMPILE == false ]] || return 99; touch "$DCT_TEST_MARKER" ;;
            *) return 99 ;;
          esac
        }
        dct_prepare_mise_ruby "$1"
      SH
      output, error, status = shell(code, RUBY_VERSION, environment: {'DCT_TEST_MARKER' => marker, 'DCT_TEST_RUBY' => prefix})
      assert status.success?, error
      assert_equal prefix, output.strip
      assert File.file?(marker)
    end
  end

  def test_mise_install_failure_does_not_trigger_source_build
    _, error, status = shell('mise() { return 1; }; ruby-build() { echo unexpected-build; }; dct_prepare_mise_ruby 3.4.6')
    refute status.success?
    assert_includes error, 'setup will not compile a private Ruby'
  end
end
