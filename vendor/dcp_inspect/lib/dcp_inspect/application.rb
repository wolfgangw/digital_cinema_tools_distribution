# frozen_string_literal: true

require "pathname"
require_relative "inspection/runtime"

module DcpInspect
  class Application
    attr_reader :arguments, :stdout, :stderr, :environment

    def initialize(arguments, stdout: $stdout, stderr: $stderr, environment: ENV)
      @arguments = arguments.dup
      @stdout = stdout
      @stderr = stderr
      @environment = environment
      @dashboard = nil
      @runtime = nil
      @logfiles_attempted = false
      @terminal_errors = []
    end

    def run
      options = CLI::Options.parse(arguments)
      binding.irb if options.debug
      options.logfile_autolog = true if environment['DCP_INSPECT_AUTOLOG']
      path = validate_path!
      validate_required_commands!(options)
      validate_log_destinations!(options, path)
      logger = build_logger(options)
      @runtime = Inspection::Runtime.new(
        options: options,
        logger: logger,
        stdout: stdout,
        dashboard: @dashboard
      )
      logger.debug "Filesystem discovery backend: #{@runtime.backend_description}"

      inspection = @runtime.call(path)
      write_logfiles_once(options, path)
      @runtime.write_model_dump(options, inspection)
      @runtime.write_result_dump(options, inspection)
      status = inspection[:errors].empty? ? Inspection::Runtime::DCP_OK : Inspection::Runtime::DCP_ERROR
      finish_dashboard(status, options.tfs)
      status
    rescue Inspection::Error => error
      log_error(error)
      finish_dashboard(error.status, false)
      error.status
    rescue Interrupt => error
      log_error("Shutdown: #{error.inspect}")
      finish_dashboard(Inspection::Runtime::USER_INTERRUPT, false)
      Inspection::Runtime::USER_INTERRUPT
    rescue SystemExit
      raise
    rescue StandardError => error
      log_internal_error(error)
      finish_dashboard(Inspection::Runtime::RUBY_EXCEPTION, false)
      Inspection::Runtime::RUBY_EXCEPTION
    ensure
      begin
        preserve_partial_logfiles(options, path) if @runtime
      ensure
        @dashboard&.stop if @dashboard&.active
        @terminal_errors.each { |message| stderr.puts(message) }
        @terminal_errors.clear
      end
    end

    private

    def write_logfiles_once(options, path)
      return if @logfiles_attempted

      @logfiles_attempted = true
      @runtime.write_logfiles(options, [path])
    end

    def preserve_partial_logfiles(options, path)
      write_logfiles_once(options, path)
    rescue StandardError => error
      # Preserve the original failure/interrupt status if saving also fails.
      message = "Could not save partial inspection log: #{error.message}"
      @dashboard&.active ? @terminal_errors << message : stderr.puts(message)
    end

    def validate_path!
      if arguments.empty?
        raise Inspection::Error.new("No volume or directory given. See #{File.basename($PROGRAM_NAME)} --help", Inspection::Runtime::NO_ARG)
      end
      if arguments.length > 1
        raise Inspection::Error.new("Too many arguments: #{arguments.inspect}", Inspection::Runtime::TOO_MANY_ARGS)
      end

      path = arguments.first
      return path if File.directory?(path) && File.directory?(Pathname(path).realpath)

      raise Inspection::Error.new("Not a volume or directory: #{path.inspect}", Inspection::Runtime::ARG_NOT_A_DIR)
    end

    def validate_required_commands!(options)
      commands = ['asdcp-info']
      commands.concat(%w[asdcp-unwrap ffmpeg]) if options.audio_analysis
      missing = commands.reject { |command| command_exists?(command) }
      return if missing.empty?

      raise Inspection::Error.new(
        "Required command#{missing.length == 1 ? '' : 's'} not found: #{missing.join(', ')}",
        Inspection::Runtime::REQUIRED_COMMAND_NOT_FOUND
      )
    end

    def validate_log_destinations!(options, path)
      if options.logfile_autolog
        directory = environment['DCP_INSPECT_DIR']
        unless directory
          raise Inspection::Error.new('Autolog requested but DCP_INSPECT_DIR is not set', Inspection::Runtime::ENV_DCP_INSPECT_DIR_NOT_SET)
        end
        unless writable_directory?(directory)
          raise Inspection::Error.new("Cannot write autolog to #{directory.inspect}", Inspection::Runtime::DCP_INSPECT_DIR_NOT_WRITABLE)
        end
        if environment['DCP_INSPECT_AUTOLOG_NAME_IS_BASENAME'] && %w[. ./ .. ../].include?(path)
          raise Inspection::Error.new("Cannot build autolog filename from #{path.inspect}", Inspection::Runtime::NO_VALID_AUTOLOG_FILENAME)
        end
      end

      validate_logfile!(options.logfile, options.overwrite_logfile) if options.logfile
      validate_logfile!(options.logfile_append, true) if options.logfile_append
    end

    def validate_logfile!(path, overwrite)
      if File.exist?(path) && !overwrite
        raise Inspection::Error.new("Requested logfile #{path.inspect} exists", Inspection::Runtime::LOGFILE_EXISTS_ERROR)
      end
      return if writable_directory?(File.dirname(path))

      raise Inspection::Error.new("Cannot write requested logfile at #{path.inspect}", Inspection::Runtime::LOGFILE_WRITE_ERROR)
    end

    def writable_directory?(directory)
      FileUtils.mkdir_p(directory)
      probe = File.join(directory, ".dcp-inspect-write-test-#{Process.pid}-#{rand(65_536)}")
      FileUtils.touch(probe)
      File.delete(probe)
      true
    rescue SystemCallError
      false
    end

    def build_logger(options)
      if options.tfs && stdout.equal?($stdout) && stdout.tty?
        @dashboard = UI::TFSRenderer.new(options)
        @dashboard.start
        UI::TFSLogger.new('', options, @dashboard, stdout)
      else
        logger = UI::DLogger.new('', options, stdout)
        logger.info '--tfs requested but stdout is not a TTY. Using regular output' if options.tfs
        logger
      end
    end

    def command_exists?(command)
      environment.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |directory|
        File.executable?(File.join(directory, command))
      end
    end

    def finish_dashboard(status, wait)
      return unless @dashboard&.active

      @dashboard.finish(status)
      @dashboard.wait_for_quit if wait
      @dashboard.stop
    end

    def log_error(error)
      message = error.respond_to?(:message) ? error.message : error.to_s
      if @dashboard&.active
        @terminal_errors << message
        @runtime&.logger&.info(message)
      else
        @runtime ? @runtime.logger.info(message) : stderr.puts(message)
      end
    end

    def log_internal_error(error)
      log_error("#{error.class}: #{error.message}")
      Array(error.backtrace).first(5).each { |line| log_error(line) }
    end
  end
end
