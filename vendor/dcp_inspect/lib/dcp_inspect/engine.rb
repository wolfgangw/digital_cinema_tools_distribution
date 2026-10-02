# frozen_string_literal: true

require "json"
require "rbconfig"
require "tempfile"

module DcpInspect
  module Engine
    class Subprocess
      def call(path, configuration:, stdout: $stdout, stderr: $stderr)
        payload = nil
        process_status = nil

        Tempfile.create(["dcp-inspect-result-", ".json"]) do |result_file|
          command = [
            RbConfig.ruby,
            DcpInspect.executable,
            *configuration.cli_arguments,
            "--dump-result",
            result_file.path,
            File.expand_path(path)
          ]
          process_status = Process.wait2(
            Process.spawn(*command, out: stdout, err: stderr)
          ).last
          result_file.rewind
          payload = JSON.parse(result_file.read) unless result_file.size.zero?
        end

        Result.new(status: process_status.exitstatus, payload: payload)
      end
    end
  end
end

require_relative "engine/native"
