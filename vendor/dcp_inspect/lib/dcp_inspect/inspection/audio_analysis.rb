# frozen_string_literal: true

module DcpInspect
  module Inspection
    class AudioAnalysis
      class Error < StandardError; end

      DIAGNOSTIC_LIMIT = 65_536
      STOP_GRACE_SECONDS = 0.5

      # Drain both helpers while watching their exit statuses. Waiting on output
      # alone can hang forever when the other end never opens the named FIFO.
      def self.run(unwrap_command, ffmpeg_command, &progress)
        new.run(unwrap_command, ffmpeg_command, &progress)
      end

      def run(unwrap_command, ffmpeg_command)
        children = {}
        streams = {}
        writers = []
        diagnostics = { unwrap: +'', ffmpeg: +'' }
        progress_buffer = +''

        unwrap_error, unwrap_writer = IO.pipe
        streams[unwrap_error] = :unwrap
        writers << unwrap_writer
        children[:unwrap] = { pid: Process.spawn(*unwrap_command, out: File::NULL, err: unwrap_writer) }
        unwrap_writer.close

        ffmpeg_error, ffmpeg_error_writer = IO.pipe
        streams[ffmpeg_error] = :ffmpeg
        writers << ffmpeg_error_writer
        ffmpeg_output, ffmpeg_output_writer = IO.pipe
        streams[ffmpeg_output] = :progress
        writers << ffmpeg_output_writer
        children[:ffmpeg] = {
          pid: Process.spawn(*ffmpeg_command, in: File::NULL, out: ffmpeg_output_writer, err: ffmpeg_error_writer)
        }
        ffmpeg_error_writer.close
        ffmpeg_output_writer.close

        until streams.empty? && children.values.all? { |child| child[:status] }
          ready = IO.select(streams.keys, nil, nil, 0.05)&.first || []
          ready.each do |io|
            chunk = io.read_nonblock(16_384, exception: false)
            next if chunk == :wait_readable

            if chunk.nil?
              streams.delete(io)
              io.close
            elsif streams[io] == :progress
              progress_buffer << chunk
              while (newline = progress_buffer.index("\n"))
                line = progress_buffer.slice!(0, newline + 1)
                yield line if block_given?
              end
            else
              name = streams[io]
              append_diagnostic(diagnostics, name, chunk)
            end
          end

          children.each_value { |child| reap(child) }
          children.each do |name, child|
            next unless child[:status] && !child[:status].success?

            # A helper can exit between select and waitpid. Collect its final
            # diagnostic bytes before reporting the failure.
            streams.each do |io, stream_name|
              next unless stream_name == name

              loop do
                chunk = io.read_nonblock(16_384, exception: false)
                break if chunk.nil? || chunk == :wait_readable

                append_diagnostic(diagnostics, name, chunk)
              end
            end
            helper = name == :unwrap ? 'asdcp-unwrap' : 'ffmpeg'
            status = child[:status]
            reason = status.signaled? ? "signal #{status.termsig}" : "exit #{status.exitstatus}"
            raise Error, "#{helper} failed (#{reason}): #{diagnostics[name].force_encoding(Encoding::UTF_8).scrub.strip}"
          end
        end

        diagnostics[:ffmpeg].force_encoding(Encoding::UTF_8).scrub
      rescue SystemCallError => error
        raise Error, "Could not run audio analysis: #{error.message}"
      ensure
        # Also clean up on Ctrl-C or a progress-rendering exception. FFmpeg can
        # ignore TERM while waiting to open a FIFO, so escalate after a grace period.
        children&.each_value { |child| signal(child, 'TERM') unless child[:status] }
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + STOP_GRACE_SECONDS
        while children&.values&.any? { |child| !child[:status] } && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          children.each_value { |child| reap(child) }
          sleep 0.01 if children.values.any? { |child| !child[:status] }
        end
        children&.each_value do |child|
          next if child[:status]

          signal(child, 'KILL')
          child[:status] = Process.waitpid2(child[:pid]).last
        end
        (streams&.keys.to_a + writers.to_a).each { |io| io.close unless io.closed? }
      end

      private

      def append_diagnostic(diagnostics, name, chunk)
        diagnostics[name] << chunk
        if diagnostics[name].bytesize > DIAGNOSTIC_LIMIT
          diagnostics[name] = diagnostics[name].byteslice(-DIAGNOSTIC_LIMIT, DIAGNOSTIC_LIMIT)
        end
      end

      def reap(child)
        return if child[:status]

        result = Process.waitpid2(child[:pid], Process::WNOHANG)
        child[:status] = result.last if result
      end

      def signal(child, name)
        Process.kill(name, child[:pid])
      rescue Errno::ESRCH
        # An exited, unreaped child is collected by reap/waitpid2.
      end
    end
  end
end
