# frozen_string_literal: true

module DcpInspect
  class Result
    attr_reader :status, :errors, :hints, :signature_info, :information,
                :inspection_run, :payload

    def initialize(status:, payload: {})
      @status = status
      @payload = payload || {}
      @errors = @payload.fetch("errors", [])
      @hints = @payload.fetch("hints", [])
      @signature_info = @payload.fetch("siginfo", [])
      @information = @payload.fetch("info", [])
      @inspection_run = @payload["inspection_run"]
    end

    def ok?
      status.zero? && errors.empty?
    end

    def exit_code
      status
    end
  end
end
