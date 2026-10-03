# frozen_string_literal: true
require_relative 'mxf_essence'
require_relative 'timing'
require 'set'

module DcpInspect
  module Inspection
    # Minimal metadata/structure inspection adapted from browser iab.js.
    # See BROWSER_BACKPORT_LICENSE. No renderer or application-profile verdict.
    module Iab
      class Error < StandardError; end
      RATES = [24, 25, 30, 48, 50, 60, 96, 100, 120, Rational(24_000, 1001)].freeze
      BLOCKS = [8, 8, 8, 4, 4, 4, 2, 2, 2, 8].freeze
      SAMPLES = [2000, 1920, 1600, 1000, 960, 800, 500, 480, 400, 2002].freeze
      ALLOWED = { 8 => [16, 64, 512, 1024, 256, 257], 16 => [16, 32], 64 => [64, 128] }.freeze

      class Reader
        attr_accessor :position
        attr_reader :limit
        def initialize(io, position, limit)
          @io, @position, @limit = io, position, limit
          @cache_start, @cache = -1, ''.b
        end
        def remaining = @limit - @position
        def bits(count)
          raise Error, "Unexpected end of IAElement at bit #{@position}" if count < 0 || count > remaining
          result = 0
          while count > 0
            byte_offset = @position / 8
            unless byte_offset >= @cache_start && byte_offset < @cache_start + @cache.bytesize
              @cache_start = byte_offset
              @io.seek(byte_offset)
              @cache = @io.read([4096, (@limit + 7) / 8 - byte_offset].min) || ''.b
            end
            byte = @cache.getbyte(byte_offset - @cache_start)
            raise Error, 'Unexpected end of file' unless byte
            take = [count, 8 - @position % 8].min
            result = (result << take) | ((byte >> (8 - @position % 8 - take)) & ((1 << take) - 1))
            @position += take
            count -= take
          end
          result
        end
        def skip(count)
          raise Error, 'Field exceeds IAElement boundary' if count < 0 || count > remaining
          @position += count
        end
        def plex(width)
          while width <= 32
            value = bits(width)
            return value if value != (1 << width) - 1
            width *= 2
          end
          raise Error, 'Plex value exceeds 32 bits'
        end
        def align
          raise Error, 'Nonzero IAB alignment bits' if @position % 8 != 0 && bits(8 - @position % 8) != 0
        end
        def bounded(length)
          raise Error, 'IAElement size exceeds its parent' if length * 8 > remaining
          self.class.new(@io, @position, @position + length * 8)
        end
      end

      class Frame
        attr_reader :beds, :objects, :errors, :header, :unknown
        def initialize(io, offset, length)
          @beds, @objects, @errors, @unknown = [], [], [], Set.new
          @metadata, @audio, @references = Set.new, Set.new, Set.new
          @element_count = 0
          reader = Reader.new(io, offset * 8, (offset + length) * 8)
          raise Error, 'Invalid IAB PreambleTag' unless reader.bits(8) == 1
          reader.skip(reader.bits(32) * 8)
          raise Error, 'Invalid IAB IAFrameTag' unless reader.bits(8) == 2
          size = reader.bits(32)
          raise Error, 'IAFrameLength does not match MXF edit-unit length' unless size * 8 == reader.remaining
          raise Error, 'Expected IAFrame element' unless element(reader, nil, 0) == 8
          raise Error, 'Trailing bytes after IAFrame' unless reader.remaining.zero?
          (@references - @audio - [0]).each { |id| @errors << "AudioDataID #{id} is referenced but absent" }
          flat = !@conditional && (@beds + @objects).all? { |item| item[:top_level] }
          if flat && @header[:max_rendered] != @beds.sum { |bed| bed[:channels] } + @objects.size
            @errors << 'MaxRendered disagrees with unconditional flat bed/object topology'
          end
        end

        def reserved(reader, count, value)
          @errors << "Invalid reserved #{count}-bit field" unless reader.bits(count) == value
        end
        def gain(reader, width = 10)
          prefix = reader.bits(2)
          @errors << 'Reserved gain/decorrelation prefix 3' if prefix == 3
          reader.bits(width) if prefix > 1
        end
        def description(reader)
          code = reader.bits(8)
          @errors << 'Reserved AudioDescription bit set' if code & 1 == 0 && code & 0x40 != 0
          return if code & 0x80 == 0
          count = 0
          loop do
            byte = reader.bits(8)
            count += 1
            raise Error, 'Non-ASCII AudioDescription' if byte > 127
            break if byte.zero?
          end
          @errors << 'AudioDescription exceeds 64 bytes' if count > 64
        end
        def metadata(reader, type)
          id = reader.plex(8)
          @errors << "Duplicate MetaID #{id} for element #{type}" unless @metadata.add?([type, id])
          id
        end
        def use_case(reader)
          value = reader.bits(8)
          @errors << "Reserved UseCase #{value}" unless [1, 2, 3, 4, 5, 6, 0x30, 0x31, 0x32, 255].include?(value)
          @errors << "D-Cinema prohibits UseCase #{value}" if value.between?(0x30, 0xfe)
        end
        def children(reader, parent, depth)
          count = reader.plex(8)
          raise Error, 'Child count exceeds available IAElement headers' if count > reader.remaining / 16
          count.times { element(reader, parent, depth + 1) }
        end
        def element(reader, parent, depth)
          raise Error, 'IAElement nesting exceeds inspection limit (32)' if depth > 32
          @element_count += 1
          raise Error, 'IAFrame element count exceeds inspection limit (10000)' if @element_count > 10_000
          type, size = reader.plex(8), reader.plex(8)
          body = reader.bounded(size)
          known = [8, 16, 32, 64, 128, 256, 257, 512, 1024].include?(type)
          @errors << "Element #{type} is not permitted in #{parent}" if parent && known && !ALLOWED.fetch(parent, []).include?(type)
          case type
          when 8
            raise Error, 'Nested IAFrame' if parent
            version, sample_code, depth_code, rate_code = body.bits(8), body.bits(2), body.bits(2), body.bits(4)
            @header = { version: version, sample_rate: [48_000, 96_000][sample_code], bit_depth: [16, 24][depth_code], rate: RATES[rate_code], rate_code: rate_code, max_rendered: body.plex(8) }
            @errors << 'Unsupported IAFrame version (expected 1)' unless version == 1
            raise Error, 'Reserved sample rate, bit depth, or frame rate code' unless @header.values_at(:sample_rate, :bit_depth, :rate).all?
            body.align
            children(body, type, depth)
          when 16 then bed(body, depth)
          when 64 then object(body, depth)
          when 32 then remap(body)
          when 128
            BLOCKS[@header[:rate_code]].times do |index|
              19.times { gain(body) } if index.zero? || body.bits(1) == 1
            end
            body.align
          when 512, 1024 then audio(body, type)
          when 256
            loop do
              byte = body.bits(8)
              break if byte.zero?
              raise Error, 'Non-ASCII AuthoringToolInfo' if byte > 127
            end
          when 257
            raise Error, 'UserData lacks its 128-bit UserID' if body.remaining < 128
            body.skip(body.remaining)
          else
            @unknown << type if @unknown.size < 100
            body.skip(body.remaining)
          end
          raise Error, "Element #{type} has unconsumed bytes" unless body.remaining.zero?
          reader.position = body.position
          type
        end
        def bed(reader, depth)
          id = metadata(reader, 16)
          conditional = reader.bits(1) == 1
          @conditional ||= conditional
          use_case(reader) if conditional
          channels = reader.plex(4)
          raise Error, 'Bed channel count exceeds available metadata' if channels > reader.remaining / 15
          ids = []
          channels.times do
            ids << reader.plex(4)
            @references << reader.plex(8)
            gain(reader)
            if reader.bits(1) == 1
              reserved(reader, 4, 0)
              gain(reader, 8)
            end
          end
          @errors << "Bed #{id} repeats ChannelID" if ids.uniq.size != ids.size
          @errors << "Bed #{id} contains reserved ChannelID" if ids.any? { |channel| channel > 0x17 && !channel.between?(0x80, 0x89) }
          @errors << "D-Cinema bed #{id} contains prohibited ChannelID above 127" if ids.any? { |channel| channel > 127 }
          reserved(reader, 10, 0x180)
          reader.align
          description(reader)
          @beds << { id: id, channels: channels, top_level: depth == 1 }
          children(reader, 16, depth)
        end
        def object(reader, depth)
          id = metadata(reader, 64)
          @references << reader.plex(8)
          if reader.bits(1) == 1
            @conditional = true
            reserved(reader, 1, 1)
            use_case(reader)
          end
          reserved(reader, 1, 0)
          BLOCKS[@header[:rate_code]].times do |index|
            next if index > 0 && reader.bits(1).zero?
            gain(reader)
            reserved(reader, 3, 1)
            reader.skip(48) # Position values: legacy Atmos coordinates vary.
            if reader.bits(1) == 1
              reader.skip(12) if reader.bits(1) == 1
              reserved(reader, 1, 0)
            end
            9.times { gain(reader) } if reader.bits(1) == 1
            mode = reader.bits(2)
            reader.skip([8, 0, 12, 36][mode])
            reserved(reader, 4, 0)
            gain(reader, 8)
          end
          reader.align
          description(reader)
          @objects << { id: id, top_level: depth == 1 }
          children(reader, 64, depth)
        end
        def remap(reader)
          metadata(reader, 32)
          use_case(reader)
          sources, destinations = reader.plex(4), reader.plex(4)
          raise Error, 'BedRemap matrix exceeds available payload' if sources * destinations * 2 > reader.remaining
          BLOCKS[@header[:rate_code]].times do |index|
            next if index > 0 && reader.bits(1).zero?
            destinations.times do
              reader.plex(4)
              sources.times { gain(reader) }
            end
          end
          reader.align
          @errors << 'Nonzero BedRemap reserved value' unless reader.plex(8).zero?
        end
        def audio(reader, type)
          id = reader.plex(8)
          @errors << "Invalid/duplicate AudioDataID #{id}" if id.zero? || !@audio.add?(id)
          if type == 512
            size = reader.bits(16)
            @errors << "AudioDataDLC #{id} payload size mismatch" unless size * 8 == reader.remaining
            sample = [48_000, 96_000][reader.bits(2)]
            @errors << "AudioDataDLC #{id} sample rate mismatch/reserved" unless sample == @header[:sample_rate]
          else
            bytes = SAMPLES[@header[:rate_code]] * (@header[:sample_rate] / 48_000) * (@header[:bit_depth] / 8)
            @errors << "AudioDataPCM #{id} payload size mismatch" unless bytes * 8 == reader.remaining
          end
          reader.skip(reader.remaining) # Audio coding/payload correctness not established.
        end
      end

      module_function
      def inspect_track(path, meta = {})
        result = { frames: 0, parsed_frames: 0, beds: nil, objects: nil, top_level_beds: nil, top_level_objects: nil,
          errors: [], unknown_elements: [], scope: 'IAFrame metadata, boundaries and references; audio payloads and profiles unchecked' }
        counts = {}
        first_header = nil
        issues = Hash.new { |h, k| h[k] = { message: k, count: 0, first_frame: nil, last_frame: nil } }
        record = lambda do |message, frame|
          message = 'Additional distinct IAB findings omitted' if !issues.key?(message) && issues.size >= 100
          item = issues[message]; item[:count] += 1; item[:first_frame] ||= frame; item[:last_frame] = frame
        end
        MxfEssence.each_packet(path) do |io, key, offset, length|
          next unless MxfEssence.kind(key) == :iab
          result[:frames] += 1
          begin
            frame = Frame.new(io, offset, length)
            result[:parsed_frames] += 1
            frame.errors.each { |message| record.call(message, result[:frames]) }
            expected_rate = Timing.rate(meta['EditRate'])
            record.call('IAFrame rate differs from MXF EditRate', result[:frames]) if expected_rate && frame.header[:rate] != expected_rate
            record.call('D-Cinema IAB requires 24-bit audio', result[:frames]) if frame.header[:bit_depth] != 24
            signature = frame.header.values_at(:version, :sample_rate, :bit_depth, :rate)
            record.call('IAFrame header changes sample rate, bit depth, version or frame rate', result[:frames]) if first_header && first_header != signature
            first_header ||= signature
            { beds: frame.beds.size, objects: frame.objects.size,
              top_level_beds: frame.beds.count { |bed| bed[:top_level] },
              top_level_objects: frame.objects.count { |object| object[:top_level] } }.each do |key, value|
              range = (counts[key] ||= { min: value, max: value })
              range[:min] = [range[:min], value].min
              range[:max] = [range[:max], value].max
            end
            result[:unknown_elements] = (result[:unknown_elements] | frame.unknown.to_a).take(100)
          rescue Error => error
            record.call(error.message, result[:frames])
          end
          yield result[:frames] if block_given?
        end
        record.call('No plaintext IAB essence frames found', 0) if result[:frames].zero?
        expected = Timing.units(meta['ContainerDuration'])
        record.call("MXF declares #{expected} frames; found #{result[:frames]}", result[:frames]) if expected && expected != result[:frames]
        counts.each { |key, range| result[key] = range }
        result[:errors] = issues.values
        result
      rescue MxfEssence::Error, SystemCallError => error
        counts.each { |key, range| result[key] = range }
        result[:errors] = issues.values + [{ message: error.message, count: 1 }]
        result
      end
    end
  end
end
