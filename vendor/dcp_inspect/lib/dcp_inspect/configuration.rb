# frozen_string_literal: true

module DcpInspect
  class Configuration
    VERBOSITY_CHOICES = %w[quiet errors hints siginfo info cpl debug dev trace_func].freeze

    attr_accessor :check_hashes, :hash_limit, :skip_png_hashes, :image_analysis, :audio_analysis,
                  :schema_validate, :as_asset_store, :verbosity, :tui,
                  :dump_model

    def initialize(
      check_hashes: true,
      hash_limit: nil,
      skip_png_hashes: false,
      image_analysis: false,
      audio_analysis: true,
      schema_validate: true,
      as_asset_store: false,
      verbosity: %w[debug dev],
      tui: false,
      dump_model: nil
    )
      @check_hashes = check_hashes
      @hash_limit = hash_limit
      @skip_png_hashes = skip_png_hashes
      @image_analysis = image_analysis
      @audio_analysis = audio_analysis
      @schema_validate = schema_validate
      @as_asset_store = as_asset_store
      @verbosity = Array(verbosity).map(&:to_s)
      @tui = tui
      @dump_model = dump_model
      validate!
    end

    def self.quick(**overrides)
      new(**{ check_hashes: false, audio_analysis: false }.merge(overrides))
    end

    def cli_arguments
      arguments = []
      arguments << "--no-hash" unless check_hashes
      arguments << "--no-png-hash" if skip_png_hashes
      arguments.concat(["--hash-limit", hash_limit.to_s]) if hash_limit
      arguments << "--no-image-analysis" unless image_analysis
      arguments << "--no-audio-analysis" unless audio_analysis
      arguments << "--no-schema" unless schema_validate
      arguments << "--as-asset-store" if as_asset_store
      arguments.concat(["--verbosity", verbosity.join(",")]) unless verbosity.empty?
      arguments << "--tfs" if tui
      arguments.concat(["--dump-model", dump_model.to_s]) if dump_model
      arguments
    end

    private

    def validate!
      invalid = verbosity - VERBOSITY_CHOICES
      raise ArgumentError, "Unknown verbosity values: #{invalid.join(', ')}" unless invalid.empty?
    end
  end
end
