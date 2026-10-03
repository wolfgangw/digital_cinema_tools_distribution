# frozen_string_literal: true
require 'tmpdir'

module DcpInspect
  module Inspection
    class TimedTextExtraction
      class Error < StandardError; end
      class Unavailable < Error; end
      LIMIT = 65_536

      # asdcp-unwrap writes the XML to the explicit output pathname and ancillary
      # resources to UUID-named files beside it. Never extract into the package.
      def self.open(path, command: ['asdcp-unwrap'], timeout: 120)
        Dir.mktmpdir('dcp-inspect-subtitles-') do |directory|
          output = File.join(directory, 'subtitle.xml')
          run([*command, File.expand_path(path), output], timeout)
          raise Error, 'Extraction succeeded without producing subtitle XML' unless File.file?(output)
          yield output, directory
        end
      end

      def self.run(command, timeout)
        reader, writer = IO.pipe
        pid = nil
        status = nil
        diagnostics = +''
        begin
          pid = Process.spawn(*command, in: File::NULL, out: File::NULL, err: writer, pgroup: true)
          writer.close
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          loop do
            if IO.select([reader], nil, nil, 0.05)
              chunk = reader.read_nonblock(4096, exception: false)
              diagnostics << chunk.byteslice(0, LIMIT - diagnostics.bytesize) if chunk.is_a?(String) && diagnostics.bytesize < LIMIT
            end
            completed = Process.waitpid2(pid, Process::WNOHANG)
            if completed
              status = completed.last
              break
            end
            raise Error, 'Timed-text extraction timed out' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          end
          raise Error, "asdcp-unwrap failed (#{status.exitstatus || "signal #{status.termsig}"}): #{diagnostics.strip}" unless status.success?
        rescue Errno::ENOENT
          raise Unavailable, 'asdcp-unwrap is unavailable; embedded subtitle inspection was not performed'
        ensure
          writer.close unless writer.closed?
          reader.close unless reader.closed?
          if pid && !status
            begin
              Process.kill('TERM', -pid)
              deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
              until Process.waitpid2(pid, Process::WNOHANG)
                if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
                  Process.kill('KILL', -pid)
                  Process.waitpid(pid)
                  break
                end
                sleep 0.01
              end
            rescue Errno::ESRCH, Errno::ECHILD
              # Already exited/reaped.
            end
          end
        end
      end
    end
  end
end
