# frozen_string_literal: true

require 'digest'
require 'json'
require 'open3'
require 'rbconfig'

module DcpInspectRelease
  PATHS = %w[dcp_inspect VERSION lib/dcp_inspect.rb lib/dcp_inspect xsd].freeze
  REQUIRED = %w[dcp_inspect VERSION lib/dcp_inspect.rb lib/dcp_inspect/application.rb xsd/catalog.xml xsd/MANIFEST.sha256].freeze

  def self.files(root)
    Dir.glob(File.join(root, '**', '*'), File::FNM_DOTMATCH).reject { |path| File.directory?(path) && !File.symlink?(path) }.map do |path|
      raise "Symlink in release: #{path}" if File.symlink?(path)
      path.delete_prefix("#{root}/")
    end.sort
  end

  def self.verify(root)
    metadata = JSON.parse(File.read(File.join(root, 'RELEASE.json')))
    expected = metadata.fetch('sha256')
    actual = files(root) - ['RELEASE.json']
    raise 'Release file list does not match RELEASE.json' unless actual == expected.keys.sort
    REQUIRED.each { |path| raise "Missing release file: #{path}" unless actual.include?(path) }
    expected.each do |path, digest|
      raise "Release checksum mismatch: #{path}" unless Digest::SHA256.file(File.join(root, path)).hexdigest == digest
    end
    version = File.read(File.join(root, 'VERSION')).strip
    raise 'Release version mismatch' unless version == metadata.fetch('version')
    schemas = File.readlines(File.join(root, 'xsd/MANIFEST.sha256')).to_h do |line|
      digest, filename = line.split
      [filename, digest]
    end
    schema_files = actual.grep(%r{\Axsd/}).map { |path| path.delete_prefix('xsd/') } - ['MANIFEST.sha256']
    raise 'Schema manifest file list mismatch' unless schema_files.sort == schemas.keys.sort
    schemas.each do |name, digest|
      raise "Schema checksum mismatch: #{name}" unless expected.fetch("xsd/#{name}") == digest
    end
    metadata
  end

  def self.smoke_test(root)
    output, error, status = Open3.capture3(RbConfig.ruby, File.join(root, 'dcp_inspect'), '--version')
    expected = File.read(File.join(root, 'VERSION')).strip
    raise "Inspector cannot start: #{output}#{error}" unless status.success? && output.include?("v#{expected}")
  end
end
