# frozen_string_literal: true

require "optparse"
require "ostruct"

module DcpInspect
  class CLI
    class Options
      VERBOSITY_CHOICES = %w[quiet errors hints siginfo info cpl debug dev trace_func].freeze

      def self.parse(arguments, program_name: File.basename($PROGRAM_NAME))
        options = defaults
        parser = build_parser(options, program_name)
        parser.parse!(arguments)
        options
      rescue OptionParser::ParseError => error
        warn "Options error: #{error.message}"
        raise SystemExit, 1
      end

      def self.from_configuration(configuration)
        options = defaults
        options.check_hashes = configuration.check_hashes
        options.skip_png_hashes = configuration.skip_png_hashes
        options.check_hashes_limit = configuration.hash_limit || :no_limit
        options.image_analysis = configuration.image_analysis
        options.audio_analysis = configuration.audio_analysis
        options.schema_validate = configuration.schema_validate
        options.as_asset_store = configuration.as_asset_store
        options.verbosity = configuration.verbosity
        options.dump_model = configuration.dump_model
        options.tfs = configuration.tui
        options
      end

      def self.defaults
        OpenStruct.new(
          check_hashes: true,
          skip_png_hashes: false,
          check_hashes_limit: :no_limit,
          image_analysis: false,
          audio_analysis: true,
          schema_validate: true,
          as_asset_store: false,
          verbosity: %w[debug dev],
          logfile: nil,
          logfile_append: nil,
          logfile_autolog: nil,
          overwrite_logfile: false,
          dump_model: nil,
          dump_result: nil,
          tfs: false,
          verbosity_choices: VERBOSITY_CHOICES,
          debug: false
        )
      end
      private_class_method :defaults

      def self.build_parser(options, program_name)
        OptionParser.new do |parser|
          parser.banner = "#{program_name} v#{DcpInspect::VERSION}\nUsage: #{program_name} [options] <path>\n"
          parser.on("--nh", "--no-hash", "No asset hash checks") { options.check_hashes = false }
          parser.on("--np", "--no-png-hash", "Skip hash checks for standalone PNG subtitle assets") { options.skip_png_hashes = true }
          parser.on("--hl", "--hash-limit limit", String, "Limit asset hash checks to assets smaller than limit") do |limit|
            options.check_hashes_limit = limit.downcase
          end
          parser.on("--ni", "--no-image-analysis", "No image analysis (not yet implemented)") do
            options.image_analysis = false
          end
          parser.on("--na", "--no-audio-analysis", "No audio analysis") { options.audio_analysis = false }
          parser.on("--no-schema", "Skip schema checks") { options.schema_validate = false }
          parser.on("-s", "--as-asset-store", "Merge all collected AssetMap dictionaries") do
            options.as_asset_store = true
          end
          parser.on("-l", "--logfile path", String, "Write full report to logfile") { |path| options.logfile = path }
          parser.on("--la", "--logfile-append path", String, "Append full report to logfile") do |path|
            options.logfile_append = path
          end
          parser.on("--autolog", "Write full report to $DCP_INSPECT_DIR") { options.logfile_autolog = true }
          parser.on("-L", "--overwrite-logfile", "Overwrite an existing logfile") do
            options.overwrite_logfile = true
          end
          parser.on("--dump-model path", String, "Write the InspectionRun model as JSON (use - for stdout)") do |path|
            options.dump_model = path
          end
          parser.on("--dump-result path", String, "Write the complete structured result as JSON") do |path|
            options.dump_result = path
          end
          parser.on("--tfs", "Use fullscreen InspectionRun dashboard output") { options.tfs = true }
          parser.on("-v", "--verbosity cutout", Array, "Select one or more report channels") do |values|
            selected = values.select { |value| VERBOSITY_CHOICES.include?(value) }
            options.verbosity = selected.empty? ? ["debug"] : selected
          end
          parser.on("-d", "--debug", "Run in the Ruby debugger") do
            options.debug = true
            begin
              require "debug"
            rescue LoadError => error
              warn error.message
              raise SystemExit, 11
            end
          end
          parser.on_tail("-h", "--help", "Display this screen") do
            puts parser
            raise SystemExit, 0
          end
          parser.on_tail("--version", "Display the version") do
            puts "#{program_name} v#{DcpInspect::VERSION}"
            raise SystemExit, 0
          end
        end
      end
      private_class_method :build_parser
    end
  end
end
