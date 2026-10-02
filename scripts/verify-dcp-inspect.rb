#!/usr/bin/env ruby
# frozen_string_literal: true
require_relative 'dcp-inspect-release'

begin
  abort 'Usage: ruby scripts/verify-dcp-inspect.rb [--runtime]' unless ARGV.empty? || ARGV == ['--runtime']
  root = File.expand_path('../vendor/dcp_inspect', __dir__)
  metadata = DcpInspectRelease.verify(root)
  DcpInspectRelease.smoke_test(root)
  if ARGV.include?('--runtime')
    %w[nokogiri ttfunk base64 openssl].each { |name| require name }
    %w[asdcp-info asdcp-unwrap ffmpeg mkfifo].each do |command|
      found = ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |directory|
        path = File.join(directory, command)
        File.file?(path) && File.executable?(path)
      end
      raise "Required command missing: #{command}" unless found
    end
    output, error, status = Open3.capture3('ffmpeg', '-hide_banner', '-filters')
    raise "Could not inspect FFmpeg filters: #{error}" unless status.success?
    %w[ebur128 astats].each do |filter|
      raise "Required FFmpeg filter missing: #{filter}" unless output.match?(/\s#{filter}\s/)
    end
  end
  puts "dcp_inspect v#{metadata.fetch('version')}: release verified (#{metadata.fetch('commit')[0, 12]})"
rescue StandardError, LoadError => error
  warn "dcp_inspect verification failed: #{error.message}"
  exit 1
end
