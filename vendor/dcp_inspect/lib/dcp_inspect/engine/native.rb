# frozen_string_literal: true

require "json"

module DcpInspect
  module Engine
    class Native
      def initialize(runtime_class: nil)
        @runtime_class = runtime_class
      end

      def call(path, configuration:, stdout: $stdout, stderr: $stderr)
        options = DcpInspect::CLI::Options.from_configuration(configuration)
        runtime = runtime_class.new(options: options, stdout: stdout)
        inspection = runtime.call(File.expand_path(path))
        payload = stringify(inspection.merge(inspection_run: inspection[:inspection_run]&.to_h))
        write_model(configuration.dump_model, payload.fetch("inspection_run"), stdout) if configuration.dump_model
        status = payload.fetch("errors", []).empty? ? 0 : 1
        Result.new(status: status, payload: payload)
      rescue DcpInspect::Inspection::Error => error
        stderr.puts(error.message)
        Result.new(status: error.status, payload: { "errors" => [error.message] })
      end

      private

      def runtime_class
        return @runtime_class if @runtime_class

        require_relative "../inspection/runtime"
        DcpInspect::Inspection::Runtime
      end

      def stringify(value)
        JSON.parse(JSON.generate(value))
      end

      def write_model(destination, model, stdout)
        contents = JSON.pretty_generate(model) + "\n"
        destination == '-' ? stdout.write(contents) : File.write(destination, contents)
      rescue SystemCallError => error
        raise DcpInspect::Inspection::Error.new(
          "Could not write inspection model #{destination.inspect}: #{error.message}",
          8
        )
      end
    end
  end
end
