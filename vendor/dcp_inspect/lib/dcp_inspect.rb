# frozen_string_literal: true

require_relative "dcp_inspect/version"
require_relative "dcp_inspect/configuration"
require_relative "dcp_inspect/result"
require_relative "dcp_inspect/timecode"
require_relative "dcp_inspect/progress"
require_relative "dcp_inspect/support/time_formatting"
require_relative "dcp_inspect/inspection/vocabulary"
require_relative "dcp_inspect/model"
require_relative "dcp_inspect/ui"
require_relative "dcp_inspect/crypto"
require_relative "dcp_inspect/filesystem_walker"
require_relative "dcp_inspect/inspection/error"
require_relative "dcp_inspect/xml/schema_store"
require_relative "dcp_inspect/xml/document_reader"
require_relative "dcp_inspect/engine"
require_relative "dcp_inspect/inspector"
require_relative "dcp_inspect/cli"

module DcpInspect
  ROOT = File.expand_path("..", __dir__).freeze
  module_function

  def executable
    File.join(ROOT, "dcp_inspect")
  end

  def xsd_dir
    File.join(ROOT, "xsd")
  end
end
