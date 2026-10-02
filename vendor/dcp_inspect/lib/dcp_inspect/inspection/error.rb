# frozen_string_literal: true

module DcpInspect
  module Inspection
    class Error < StandardError
      attr_reader :status

      def initialize(message, status = 1)
        super(message)
        @status = status
      end
    end
  end
end
