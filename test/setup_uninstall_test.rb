# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'

class SetupUninstallTest < Minitest::Test
  SETUP = File.expand_path('../digital-cinema-tools-setup', __dir__)

  def shell(code, *arguments, input: '')
    Open3.capture3('bash', '-c', 'source "$1"; shift; ' + code, 'test', SETUP, *arguments, stdin_data: input)
  end

  def installation
    Dir.mktmpdir('dct user with spaces ') do |user_dir|
      base = File.join(user_dir, '.digital_cinema_tools')
      FileUtils.mkdir_p(File.join(base, '.bin'))
      File.write(File.join(base, 'owned-file'), 'tool content')
      yield user_dir, base
    end
  end

  def test_no_empty_answer_and_eof_preserve_everything
    ["n\n", "\n", ''].each do |answer|
      installation do |user_dir, base|
        rc = File.join(user_dir, '.bashrc')
        File.write(rc, "# user configuration\n")
        output, error, status = shell('dct_uninstall "$1"', user_dir, input: answer)
        assert status.success?, error
        assert_includes output, 'cancelled'
        assert File.file?(File.join(base, 'owned-file'))
        assert_equal "# user configuration\n", File.read(rc)
      end
    end
  end

  def test_managed_path_is_reversible_and_does_not_duplicate_on_install
    installation do |user_dir, base|
      rc = File.join(user_dir, '.bashrc')
      File.write(rc, "export USER_SETTING=keep\n")
      2.times do
        _, error, status = shell('dct_add_path "$1" "$2"', rc, File.join(base, '.bin'))
        assert status.success?, error
      end
      assert_equal 1, File.read(rc).scan('# >>> digital-cinema-tools PATH >>>').size
      _, error, status = shell('dct_uninstall "$1"', user_dir, input: "yes\n")
      assert status.success?, error
      refute File.exist?(base)
      assert_equal "export USER_SETTING=keep\n\n", File.read(rc)
    end
  end

  def test_removes_recognizable_rbenv_and_completion_entries_but_keeps_shared_configuration
    installation do |user_dir, base|
      rc = File.join(user_dir, '.bashrc')
      File.write(rc, <<~SH)
        # user configuration
        # digital-cinema-tools-setup: Add #{base}/.bin to PATH
        export PATH=#{base}/.bin:$PATH
        # digital-cinema-tools-setup: rbenv environment
        export RBENV_ROOT=#{base}/.lib/.rbenv
        export PATH=#{base}/.lib/.rbenv/bin:$PATH
        eval "$(rbenv init -)"
        eval "$(mise activate bash)"
        export PATH=/user/bin:$PATH
      SH
      File.write(File.join(user_dir, '.inputrc'), "# digital-cinema-tools-setup: This will make completions show up after 1 TAB hit\nset show-all-if-ambiguous on\nset editing-mode vi\n")
      File.write(File.join(user_dir, '.gemrc'), "gem: --no-document\n")
      shared = File.join(user_dir, '.local/share/mise/installs/ruby')
      FileUtils.mkdir_p(shared)
      _, error, status = shell('dct_uninstall "$1"', user_dir, input: "y\n")
      assert status.success?, error
      refute File.exist?(base)
      assert_equal "# user configuration\neval \"$(mise activate bash)\"\nexport PATH=/user/bin:$PATH\n", File.read(rc)
      assert_equal "set editing-mode vi\n", File.read(File.join(user_dir, '.inputrc'))
      assert_equal "gem: --no-document\n", File.read(File.join(user_dir, '.gemrc'))
      assert File.directory?(shared)
    end
  end

  def test_preserves_user_modified_and_unmarked_path_settings
    installation do |user_dir, base|
      content = <<~SH
        # >>> digital-cinema-tools PATH >>>
        export PATH=/user/custom:$PATH
        # <<< digital-cinema-tools PATH <<<
        export PATH=#{base}/.bin:$PATH
      SH
      File.write(File.join(user_dir, '.bashrc'), content)
      _, _, status = shell('dct_uninstall "$1"', user_dir, input: "y\n")
      assert status.success?
      assert_equal content, File.read(File.join(user_dir, '.bashrc'))
    end
  end

  def test_cleans_symlinked_bashrc_without_replacing_link_and_preserves_mode
    installation do |user_dir, base|
      target = File.join(user_dir, 'dotfiles/bashrc')
      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, "# keep\n")
      File.chmod(0o640, target)
      rc = File.join(user_dir, '.bashrc')
      File.symlink('dotfiles/bashrc', rc)
      shell('dct_add_path "$1" "$2"', rc, File.join(base, '.bin'))
      _, error, status = shell('dct_uninstall "$1"', user_dir, input: "y\n")
      assert status.success?, error
      assert File.symlink?(rc)
      assert_equal "# keep\n\n", File.read(target)
      assert_equal 0o640, File.stat(target).mode & 0o777
    end
  end

  def test_installation_symlink_target_is_never_deleted
    Dir.mktmpdir do |directory|
      user_dir = File.join(directory, 'user')
      elsewhere = File.join(directory, 'shared-data')
      FileUtils.mkdir_p([user_dir, elsewhere])
      File.write(File.join(elsewhere, 'keep'), 'untouched')
      File.symlink(elsewhere, File.join(user_dir, '.digital_cinema_tools'))
      _, error, status = shell('dct_uninstall "$1"', user_dir, input: "y\n")
      assert status.success?, error
      assert_equal 'untouched', File.read(File.join(elsewhere, 'keep'))
      refute File.symlink?(File.join(user_dir, '.digital_cinema_tools'))
    end
  end

  def test_uninstall_from_inside_tree_and_repeated_uninstall
    installation do |user_dir, base|
      inputrc = File.join(user_dir, '.inputrc')
      File.write(inputrc, "# digital-cinema-tools-setup: This will make completions show up after 1 TAB hit\nset show-all-if-ambiguous on\n")
      installed = File.join(base, 'setup')
      FileUtils.cp(SETUP, installed)
      output, error, status = Open3.capture3('bash', '-c', 'source "$1"; cd "$2/.digital_cinema_tools"; dct_uninstall "$2"', 'test', installed, user_dir, stdin_data: "y\n")
      assert status.success?, "#{output}#{error}"
      refute File.exist?(base)
      refute File.exist?(inputrc)
      _, error, status = shell('dct_uninstall "$1"', user_dir, input: "y\n")
      assert status.success?, error
    end
  end

  def test_rejects_unsafe_root_before_confirmation
    _, error, status = shell('dct_uninstall /', input: "y\n")
    refute status.success?
    assert_includes error, 'safe home directory'
  end

  def test_help_and_unknown_argument_do_not_require_dependencies
    output, _, status = Open3.capture3({'PATH' => '/nonexistent'}, '/bin/bash', SETUP, '--help')
    assert status.success?
    assert_includes output, 'uninstall'
    _, _, status = Open3.capture3({'PATH' => '/nonexistent'}, '/bin/bash', SETUP, 'unknown')
    assert_equal 2, status.exitstatus
  end
end
