# frozen_string_literal: true
require_relative 'mxf_essence'
require_relative 'timing'

module DcpInspect
  module Inspection
    # Cinema header checks adapted from browser jpeg2000-codestream-scan.js.
    # See BROWSER_BACKPORT_LICENSE. Compressed packet bodies are never decoded.
    module Jpeg2000Headers
      class Error < StandardError; end
      SIZ_FIELDS = %w[Rsize Xsize Ysize XOsize YOsize XTsize YTsize XTOsize YTOsize].freeze
      module_function
      def read(io, count, limit)
        raise Error, 'JPEG2000 marker extends beyond the codestream' if count < 0 || io.pos + count > limit
        bytes = io.read(count)
        raise Error, 'Truncated JPEG2000 marker' unless bytes && bytes.bytesize == count
        bytes
      end
      def u16(bytes, offset = 0) = bytes.byteslice(offset, 2)&.unpack1('n')
      def u32(bytes, offset = 0) = bytes.byteslice(offset, 4)&.unpack1('N')

      def inspect_frame(io, start, size, descriptor = {})
        limit = start + size
        io.seek(start)
        raise Error, 'Missing JPEG2000 SOC' unless read(io, 2, limit) == "\xff\x4f".b
        segments, tiles, errors = Hash.new { |h, k| h[k] = [] }, [], []
        tile_end = nil
        ended = false
        markers = 0
        while io.pos < limit
          markers += 1
          raise Error, 'JPEG2000 header marker count exceeds inspection limit' if markers > 16_384
          offset = io.pos
          marker = u16(read(io, 2, limit))
          if marker == 0xffd9
            raise Error, 'EOC before tile-part SOD' if tile_end
            ended = true
            errors << 'Bytes follow JPEG2000 EOC' unless io.pos == limit
            break
          end
          if marker == 0xff93
            raise Error, 'SOD without a bounded SOT tile part' unless tile_end && tile_end >= io.pos
            io.seek(tile_end)
            tile_end = nil
            next
          end
          raise Error, "Invalid JPEG2000 marker 0x#{marker.to_s(16)}" unless (marker & 0xff00) == 0xff00
          length = u16(read(io, 2, limit))
          raise Error, 'Invalid marker segment length' unless length >= 2
          bytes = read(io, length - 2, tile_end || limit)
          if marker == 0xff90
            raise Error, 'Nested SOT before SOD' if tile_end
            raise Error, 'Invalid SOT segment length' unless bytes.size == 8
            tile, span, part, parts = bytes.unpack('nNCC')
            raise Error, 'Invalid or unbounded SOT tile-part length' if span < 14 || offset + span > limit
            tile_end = offset + span
            tiles << { tile: tile, length: span, part: part, parts: parts }
          else
            errors << "Cinema tile-part header contains marker 0x#{marker.to_s(16)}" if tile_end && marker != 0xff64
            segments[marker] << bytes
          end
        end
        errors << 'Missing JPEG2000 EOC' unless ended
        raise Error, 'Missing or repeated SIZ/COD/QCD marker' unless [0xff51, 0xff52, 0xff5c].all? { |m| segments[m].size == 1 }
        siz, cod, qcd = segments[0xff51].first, segments[0xff52].first, segments[0xff5c].first
        raise Error, 'Truncated SIZ/COD/QCD marker' if siz.size < 36 || cod.size < 10 || qcd.empty?
        profile = u16(siz)
        xs, ys, xo, yo, xt, yt, xto, yto = siz.byteslice(2, 32).unpack('N8')
        components = u16(siz, 34)
        raise Error, 'Invalid SIZ component count/length' unless components > 0 && siz.size == 36 + 3 * components
        raise Error, 'Invalid SIZ dimensions or tile size' unless xs > xo && ys > yo && xt > 0 && yt > 0 && xs > xto && ys > yto
        width, height = xs - xo, ys - yo
        siz_fields = SIZ_FIELDS.zip([profile, xs, ys, xo, yo, xt, yt, xto, yto]).to_h
        siz_fields.each do |field, observed|
          next unless descriptor.key?(field)
          declared = Timing.units(descriptor[field])
          unless declared == observed
            errors << "MXF JPEG2000 descriptor #{field}=#{descriptor[field].inspect} differs from essence SIZ #{field}=#{observed}"
          end
        end
        four_k = width > 2048 || height > 1080
        expected_parts = four_k ? 6 : 3
        errors << "DCI cinema SIZ profile must be #{four_k ? 4 : 3}; found #{profile}" unless profile == (four_k ? 4 : 3)
        errors << 'Cinema dimensions/origins exceed the profile' unless width <= (four_k ? 4096 : 2048) && height <= (four_k ? 2160 : 1080) && [xo, yo, xto, yto].all?(&:zero?)
        errors << 'Cinema JPEG2000 must use one tile' unless (xs - xto + xt - 1) / xt * ((ys - yto + yt - 1) / yt) == 1
        errors << 'Cinema JPEG2000 requires three unsigned 12-bit, unsubsampled components' unless components == 3 && siz.byteslice(36..).bytes.each_slice(3).all? { |values| values == [11, 1, 1] }
        if descriptor['StoredWidth'] && descriptor['StoredHeight']
          errors << 'SIZ dimensions differ from MXF picture descriptor' unless width == Timing.units(descriptor['StoredWidth']) && height == Timing.units(descriptor['StoredHeight'])
        end
        levels = cod.getbyte(5)
        errors << 'COD must declare one quality layer' unless u16(cod, 2) == 1
        errors << 'COD requires 32x32 codeblocks with zero coding-style flags' unless cod.byteslice(6, 3).bytes == [3, 3, 0]
        errors << 'COD declares invalid cinema coding parameters/precincts' unless
          levels.between?(four_k ? 1 : 0, four_k ? 6 : 5) && [0, 1].include?(cod.getbyte(4)) && [0, 1].include?(cod.getbyte(9)) &&
          cod.getbyte(0) & 1 == 1 && cod.getbyte(0) & ~7 == 0 && cod.byteslice(10..).bytes == [0x77] + [0x88] * levels
        errors << 'QCD guard bits do not match cinema resolution' unless qcd.getbyte(0) >> 5 == (four_k ? 2 : 1)
        errors << "Cinema requires #{expected_parts} ordered tile parts" unless tiles.size == expected_parts && tiles.each_with_index.all? { |tile, index| tile[:tile].zero? && tile[:part] == index && [0, expected_parts].include?(tile[:parts]) }
        if four_k
          expected = [[0, 0, 1, levels, 3, 4], [levels, 0, 1, levels + 1, 3, 4]].map { |entry| entry.pack('CCnCCC') }.join
          errors << '4K requires the two cinema CPRL progressions in one POC' unless segments[0xff5f] == [expected]
        else
          errors << '2K requires CPRL progression and no POC' unless cod.getbyte(1) == 4 && segments[0xff5f].empty?
        end
        # COC/QCC and ROI alter common-header interpretation. Do not silently
        # report a clean subset when this inspector cannot validate overrides.
        overrides = [0xff53, 0xff5d, 0xff5e].select { |m| segments[m].any? }
        tlm = segments[0xff55]
        entries = []
        tlm.each_with_index do |bytes, index|
          raise Error, 'Truncated/non-sequential TLM' if bytes.size < 2 || bytes.getbyte(0) != index
          flags = bytes.getbyte(1)
          tile_bytes, length_bytes = (flags >> 4) & 3, flags & 0x40 == 0 ? 2 : 4
          raise Error, 'Invalid TLM flags/entry length' if tile_bytes == 3 || flags & 0x8f != 0 || (bytes.size - 2) % (tile_bytes + length_bytes) != 0
          bytes.byteslice(2..).bytes.each_slice(tile_bytes + length_bytes) do |row|
            tile = row.take(tile_bytes).reduce(0) { |n, byte| (n << 8) | byte }
            span = row.drop(tile_bytes).reduce(0) { |n, byte| (n << 8) | byte }
            entries << [tile, span]
          end
        end
        errors << 'TLM is missing or disagrees with SOT tile-part lengths' unless tlm.any? && entries == tiles.map { |tile| [tile[:tile], tile[:length]] }
        { errors: errors, unchecked_overrides: overrides, width: width, height: height, profile: profile,
          components: components, decomposition_levels: levels, tile_parts: tiles.size, siz: siz_fields }
      end

      def inspect_track(path, descriptor = {})
        result = { codestreams: 0, checked: 0, errors: [], unchecked_overrides: [], first_header: nil,
          descriptor_fields_checked: SIZ_FIELDS.select { |field| descriptor.key?(field) },
          unchecked_descriptor_fields: SIZ_FIELDS.reject { |field| descriptor.key?(field) },
          scope: 'Plaintext JPEG2000 headers and tile-part boundaries; compressed packets/pixels unchecked' }
        issues = {}
        record = lambda do |message|
          key = issues.key?(message) || issues.size < 100 ? message : 'Additional distinct JPEG2000 findings omitted'
          item = (issues[key] ||= { message: key, count: 0, first_codestream: result[:codestreams] })
          item[:count] += 1; item[:last_codestream] = result[:codestreams]
        end
        MxfEssence.each_packet(path) do |io, key, offset, length|
          next unless MxfEssence.kind(key) == :jpeg2000
          result[:codestreams] += 1
          begin
            header = inspect_frame(io, offset, length, descriptor)
            result[:checked] += 1
            result[:first_header] ||= header.reject { |k, _| k == :errors }
            header[:errors].each { |message| record.call(message) }
            result[:unchecked_overrides] |= header[:unchecked_overrides]
          rescue Error => error
            record.call(error.message)
          end
          yield result[:codestreams] if block_given?
        end
        record.call('No plaintext JPEG2000 codestreams found') if result[:codestreams].zero?
        expected = Timing.units(descriptor['ContainerDuration'])
        expected *= 2 if expected && descriptor['EssenceType'].to_s.downcase.include?('stereoscopic')
        record.call("MXF declares #{expected} codestreams; found #{result[:codestreams]}") if expected && expected != result[:codestreams]
        result[:errors] = issues.values
        result
      rescue MxfEssence::Error, SystemCallError => error
        result[:errors] = issues.values + [{ message: error.message, count: 1 }]
        result
      end
    end
  end
end
