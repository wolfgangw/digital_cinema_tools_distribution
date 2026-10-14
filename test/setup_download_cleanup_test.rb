require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'

class SetupDownloadCleanupTest < Minitest::Test
  SETUP = File.expand_path('../digital-cinema-tools-setup', __dir__)

  def exercise(kind, exit_code: 0)
    Dir.mktmpdir('dct-cleanup-test') do |dir|
      download_dir = File.join(dir, 'download space')
      FileUtils.mkdir_p(download_dir)
      download = File.join(download_dir, 'digital-cinema-tools-setup')
      installed = File.join(dir, 'installed-setup')
      File.write(installed, "#!/bin/bash\n")
      File.chmod(0o755, installed)
      File.write(download, "downloaded setup\n")
      case kind
      when :symlink
        File.unlink(download)
        File.symlink(installed, download)
      when :installed
        installed = download
        File.chmod(0o755, installed)
      when :checkout
        _, error, status = Open3.capture3('git', 'init', download_dir)
        assert status.success?, error
      when :missing_install
        File.unlink(installed)
      end
      script = <<~BASH
        source "$1"
        dct_track_setup_download "$2" "$3"
        #{'printf changed > "$2"' if kind == :modified}
        cd /
        exit #{exit_code}
      BASH
      _, error, status = Open3.capture3({'TMPDIR' => dir}, 'bash', '-c', script,
                                       'test', SETUP, download, installed)
      assert_equal exit_code, status.exitstatus, error
      assert_equal kind != :download || exit_code != 0, File.exist?(download)
      assert_empty Dir.glob(File.join(dir, 'dct-download.*'))
    end
  end

  def test_success_removes_standalone_download_even_after_changing_directory
    exercise(:download)
  end

  def test_failed_install_preserves_download_and_exit_status
    exercise(:download, exit_code: 7)
  end

  def test_preserves_installed_scripts_symlinks_checkouts_and_changed_downloads
    %i[installed symlink checkout modified missing_install].each { |kind| exercise(kind) }
  end
end
