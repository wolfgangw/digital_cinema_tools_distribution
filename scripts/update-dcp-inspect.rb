#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require_relative 'dcp-inspect-release'

# Export only committed runtime files; the source checkout is never modified.
def git(source, *arguments)
  output, error, status = Open3.capture3('git', '-C', source, *arguments)
  raise "git #{arguments.first}: #{error}" unless status.success?
  output
end

begin
  abort 'Usage: ruby scripts/update-dcp-inspect.rb /path/to/backports [commit-or-tag]' unless (1..2).cover?(ARGV.length)
  source = File.expand_path(ARGV[0])
  revision = ARGV[1] || 'HEAD'
  dirty = git(source, 'status', '--porcelain', '--untracked-files=all', '--', *DcpInspectRelease::PATHS)
  raise 'Commit or stash changes to inspector runtime files before exporting a release' unless dirty.empty?
  commit = git(source, 'rev-parse', '--verify', '--end-of-options', "#{revision}^{commit}").strip
  distribution = File.expand_path('..', __dir__)
  vendor = File.join(distribution, 'vendor')
  destination = File.join(vendor, 'dcp_inspect')
  FileUtils.mkdir_p(vendor)
  Dir.mktmpdir('.dcp-inspect-release-', vendor) do |temporary|
    stage = File.join(temporary, 'bundle')
    Dir.mkdir(stage)
    listing = git(source, 'ls-tree', '-rz', commit, '--', *DcpInspectRelease::PATHS)
    listing.split("\0").each do |entry|
      attributes, path = entry.split("\t", 2)
      mode, type, object = attributes.split
      raise "Unsupported release entry: #{path}" unless type == 'blob' && %w[100644 100755].include?(mode)
      target = File.join(stage, path)
      FileUtils.mkdir_p(File.dirname(target))
      File.binwrite(target, git(source, 'cat-file', 'blob', object))
      File.chmod(mode == '100755' ? 0o755 : 0o644, target)
    end
    version = File.read(File.join(stage, 'VERSION')).strip
    checksums = DcpInspectRelease.files(stage).to_h { |path| [path, Digest::SHA256.file(File.join(stage, path)).hexdigest] }
    metadata = { 'source' => 'https://github.com/wolfgangw/backports', 'commit' => commit,
                 'version' => version, 'sha256' => checksums }
    File.write(File.join(stage, 'RELEASE.json'), JSON.pretty_generate(metadata) + "\n")
    DcpInspectRelease.verify(stage)
    DcpInspectRelease.smoke_test(stage)
    # Replace only this generated bundle after validating the complete snapshot.
    # Keep the previous bundle available for rollback until the rename succeeds.
    backup = File.join(vendor, ".dcp-inspect-previous-#{Process.pid}")
    raise "Backup path already exists: #{backup}" if File.exist?(backup)
    File.rename(destination, backup) if File.exist?(destination)
    begin
      File.rename(stage, destination)
    rescue Exception
      File.rename(backup, destination) if File.exist?(backup)
      raise
    end
    FileUtils.rm_rf(backup)
    puts "Bundled dcp_inspect v#{version} from #{commit}"
    puts 'Review git diff, run ruby test/dcp_inspect_distribution_test.rb, then commit the release.'
  end
rescue StandardError => error
  warn "Release export failed: #{error.message}"
  exit 1
end
