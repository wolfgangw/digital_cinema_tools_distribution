# frozen_string_literal: true

module DcpInspect
  class Inspector
    attr_reader :configuration, :engine

    def initialize(configuration: Configuration.new, engine: Engine::Native.new)
      @configuration = configuration
      @engine = engine
    end

    def call(path, stdout: $stdout, stderr: $stderr)
      engine.call(path, configuration: configuration, stdout: stdout, stderr: stderr)
    end
  end
end
