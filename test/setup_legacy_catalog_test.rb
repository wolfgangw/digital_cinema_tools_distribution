require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'

class SetupLegacyCatalogTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  OLD_PATH = '/home/wolfgang/opencinema/backports/xsd/'

  def git(repo, *args)
    out, err, status = Open3.capture3('git', '-C', repo, *args)
    assert status.success?, err
    out
  end

  def exercise(change, mode: 'install')
    Dir.mktmpdir('dct-catalog-test') do |dir|
      repo = File.join(dir, 'installation with spaces & punctuation')
      FileUtils.mkdir_p(File.join(repo, 'xsd'))
      catalog = File.join(repo, 'xsd/catalog.xml')
      original = File.binread(File.join(ROOT, 'xsd/catalog.xml')).sub('xml:base="./"', "xml:base=\"file://#{OLD_PATH}\"")
      File.binwrite(catalog, original)
      git(repo, 'init', '-q')
      git(repo, 'config', 'user.name', 'Test')
      git(repo, 'config', 'user.email', 'test@example.invalid')
      git(repo, 'config', 'core.filemode', 'true')
      git(repo, 'add', '.')
      git(repo, 'commit', '-qm', 'Initial')
      git(repo, 'remote', 'add', 'origin', repo)
      revision = git(repo, 'rev-parse', 'HEAD').strip
      rewritten = original.gsub(OLD_PATH, File.realpath(File.join(repo, 'xsd')) + '/')
      File.binwrite(catalog, rewritten)
      case change
      when :extra_edit then File.open(catalog, 'a') { |file| file.puts '<!-- user edit -->' }
      when :wrong_path then File.binwrite(catalog, original.gsub(OLD_PATH, '/some/other/xsd/'))
      when :staged then git(repo, 'add', 'xsd/catalog.xml')
      when :mode then File.chmod(0o755, catalog)
      when :unrelated then File.write(File.join(repo, 'notes'), 'keep me')
      when :symlink
        target = File.join(dir, 'catalog-target')
        File.rename(catalog, target)
        File.symlink(target, catalog)
      end
      before = File.binread(catalog)
      script = <<~'BASH'
        source "$1"
        dct_download() {
          case "$1" in
            */commits/master) printf '  "sha": "%s",\n' "$published_revision" > "$2" ;;
            *) printf 'echo handoff-complete\n' > "$2" ;;
          esac
        }
        dct_update "$mode" "$1" "$repo"
      BASH
      out, err, status = Open3.capture3({'published_revision' => revision, 'mode' => mode,
                                       'repo' => repo, 'TMPDIR' => dir},
        'bash', '-c', script, 'test', File.join(ROOT, 'digital-cinema-tools-setup'))
      migrated = mode == 'install'
      assert_equal migrated ? original : before, File.binread(catalog)
      if mode == 'check' || change != :unrelated
        assert status.success?, err
      else
        refute status.success?
        assert_includes err, 'local changes'
        refute_includes out, 'handoff-complete'
      end
      if change != :unrelated && mode == 'install'
        assert_includes out, 'handoff-complete'
        assert_equal '', git(repo, 'status', '--porcelain')
      end
      refute File.symlink?(catalog) if change == :symlink
      assert_equal 'keep me', File.read(File.join(repo, 'notes')) if change == :unrelated
    end
  end

  def test_legacy_rewrite_is_migrated_and_update_proceeds
    exercise(:legacy)
  end

  def test_catalog_changes_are_discarded_but_unrelated_changes_still_block_updates
    %i[extra_edit wrong_path staged mode symlink unrelated].each { |change| exercise(change) }
  end

  def test_check_update_does_not_modify_catalog
    exercise(:legacy, mode: 'check')
  end
end
