# frozen_string_literal: true

require_relative "cli/options"

module DcpInspect
  class CLI
    class << self
      def start(arguments = ARGV)
        require_relative "application"
        status = DcpInspect::Application.new(arguments).run
        raise SystemExit, status unless status.zero?
        status
      end
    end
  end
end
