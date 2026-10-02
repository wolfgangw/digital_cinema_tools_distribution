require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'

class SetupUpdateTest < Minitest::Test
  SETUP = File.expand_path('../digital-cinema-tools-setup', __dir__)
  REV = 'a' * 40

  def run_update(mode, body:, git: '', failure: false)
    Dir.mktmpdir('dct-update-test') do |dir|
      candidate = File.join(dir, 'candidate')
      File.write(candidate, body)
      script = <<~BASH
        source "$1"
        dct_download() {
          #{'return 1' if failure}
          case "$1" in
            */commits/master) printf '  "sha": "#{REV}",\\n' > "$2" ;;
            */#{REV}/digital-cinema-tools-setup) cp "$candidate" "$2" ;;
            *) return 99 ;;
          esac
        }
        git() { #{git.empty? ? 'return 1' : git}; }
        dct_update "$mode" "$candidate" "$installed"
      BASH
      Open3.capture3({'candidate' => candidate, 'installed' => dir, 'mode' => mode, 'TMPDIR' => dir},
                    'bash', '-c', script, 'test', SETUP).tap do
        assert_equal ['candidate'], Dir.children(dir).sort, 'temporary update files cleaned up'
      end
    end
  end

  def test_current_installation
    out, err, status = run_update('check', body: '#!/bin/bash', git: "echo #{REV}")
    assert status.success?, err
    assert_includes out, 'is up to date'
  end

  def test_bundle_update_with_unchanged_script
    out, err, status = run_update('check', body: '#!/bin/bash', git: "echo #{'b' * 40}")
    assert status.success?, err
    assert_includes out, 'update is available'
  end

  def test_handoff_pins_revision_and_preserves_exit_status
    out, _, status = run_update('install', body: 'printf "%s %s" "$DCT_SETUP_REVISION" "$1"; exit 7')
    assert_equal 7, status.exitstatus
    assert_equal "#{REV} --no-self-update", out
  end

  def test_offline_stops_without_handoff
    out, err, status = run_update('install', body: 'echo should-not-run', failure: true)
    refute status.success?
    refute_includes out, 'should-not-run'
    assert_includes err, 'Cannot check for updates'
  end

  def test_invalid_download_is_not_executed
    _, _, status = run_update('install', body: 'if invalid shell')
    refute status.success?
  end

  def test_dirty_checkout_stops_before_handoff
    out, err, status = run_update('install', body: 'echo should-not-run', git: "echo #{REV}")
    refute status.success?
    refute_includes out, 'should-not-run'
    assert_includes err, 'local changes'
  end

  def test_check_does_not_execute_download_or_fetch
    out, err, status = run_update('check', body: 'echo should-not-run', git: '[[ $3 == rev-parse ]] || exit 88; echo old')
    assert status.success?, err
    refute_includes out, 'should-not-run'
  end
end
