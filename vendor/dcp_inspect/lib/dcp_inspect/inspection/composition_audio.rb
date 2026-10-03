# frozen_string_literal: true
require_relative 'mxf_essence'
require_relative 'timing'
require_relative 'pcm_layout'
require_relative 'audio_analysis'

module DcpInspect
  module Inspection
    # Stream exact CPL PCM windows in reel order into ONE BS.1770/EBU R128
    # measurement. Never average per-reel LUFS and never concatenate WAV headers.
    module CompositionAudio
      Error = AudioAnalysis::Error
      PCM = ['060e2b34010201010d010301160101'].pack('H*').freeze
      module_function
      def chunks(segments, opened: [])
        Enumerator.new do |output|
          segments.each do |segment|
            count = 0
            frame = 0
            expected_bytes = segment[:samples_per_frame] * segment[:channels] * 3
            MxfEssence.each_packet(segment[:path], on_open: ->(io) { opened << io }) do |io, key, offset, length|
              next unless key.byteslice(0, 15) == PCM
              if frame >= segment[:entry] && count < segment[:duration]
                raise Error, "PCM edit unit #{frame} has #{length} bytes; expected #{expected_bytes}" unless length == expected_bytes
                io.seek(offset)
                remaining = length
                while remaining > 0
                  bytes = io.read([remaining, 65_536].min)
                  raise Error, 'PCM packet is truncated' unless bytes && !bytes.empty?
                  output << bytes
                  remaining -= bytes.bytesize
                end
                count += 1
              end
              frame += 1
              break if count == segment[:duration]
            end
            raise Error, "Only #{count}/#{segment[:duration]} selected PCM edit units available" unless count == segment[:duration]
          end
        rescue MxfEssence::Error, SystemCallError => error
          raise Error, error.message
        end
      end

      def measure(segments, layout, command: nil)
        first = segments.first
        # Convert sample format before remapping: combining both can make FFmpeg
        # rematrix/attenuate channels according to its guessed input layout.
        command ||= ['ffmpeg', '-hide_banner', '-nostats', '-nostdin', '-v', 'info',
          '-f', 's24le', '-ar', first[:sample_rate].to_s, '-ac', first[:channels].to_s,
          '-i', 'pipe:0', '-af', "aformat=sample_fmts=dbl,#{PcmLayout.pan(layout)},ebur128=peak=true,astats=metadata=0:reset=0",
          '-f', 'null', '-']
        input_read, input_write = IO.pipe
        errors_read, errors_write = IO.pipe
        pid = nil
        status = nil
        diagnostic = +''
        opened = []
        stream = chunks(segments, opened: opened)
        pending = ''.b
        finished = false
        bytes_written = 0
        total_bytes = segments.sum { |s| s[:duration] * s[:samples_per_frame] * s[:channels] * 3 }
        begin
          pid = Process.spawn(*command, in: input_read, out: File::NULL, err: errors_write)
          input_read.close
          errors_write.close
          until status && errors_read.closed?
            if pending.empty? && !finished
              begin
                pending = stream.next
              rescue StopIteration
                finished = true
                input_write.close
              end
            end
            readers = errors_read.closed? ? [] : [errors_read]
            writers = finished ? [] : [input_write]
            ready = IO.select(readers, writers, nil, 0.05)
            if ready && ready[0].include?(errors_read)
              bytes = errors_read.read_nonblock(16_384, exception: false)
              if bytes.nil?
                errors_read.close
              elsif bytes.is_a?(String)
                diagnostic << bytes
                diagnostic = diagnostic.byteslice(-AudioAnalysis::DIAGNOSTIC_LIMIT, AudioAnalysis::DIAGNOSTIC_LIMIT) if diagnostic.bytesize > AudioAnalysis::DIAGNOSTIC_LIMIT
              end
            end
            if ready && ready[1].include?(input_write)
              amount = input_write.write_nonblock(pending, exception: false)
              if amount.is_a?(Integer)
                pending = pending.byteslice(amount..)
                bytes_written += amount
                yield bytes_written, total_bytes if block_given?
              end
            end
            status ||= Process.waitpid2(pid, Process::WNOHANG)&.last
            raise Error, "ffmpeg composition analysis failed: #{diagnostic.force_encoding(Encoding::UTF_8).scrub.strip}" if status && (!status.success? || !finished)
          end
          raise Error, 'Composition PCM stream did not match the full requested timeline' unless bytes_written == total_bytes
          diagnostic.force_encoding(Encoding::UTF_8).scrub
        rescue SystemCallError => error
          raise Error, "Composition audio analysis failed: #{error.message}"
        ensure
          (opened + [input_read, input_write, errors_read, errors_write]).each { |io| io.close unless io.closed? }
          if pid && !status
            begin
              Process.kill('TERM', pid)
              deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
              until Process.waitpid2(pid, Process::WNOHANG)
                if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
                  Process.kill('KILL', pid)
                  Process.waitpid(pid)
                  break
                end
                sleep 0.01
              end
            rescue Errno::ESRCH, Errno::ECHILD
              # Child already exited/reaped.
            end
          end
        end
      end
    end
  end
end
