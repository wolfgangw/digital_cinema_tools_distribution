# frozen_string_literal: true

module DcpInspect
  module Inspection
    # Sequential KLV walk: lengths are authoritative; never search inside a
    # damaged essence payload for a plausible next packet.
    module MxfEssence
      class Error < StandardError; end
      PREFIX = [0x06, 0x0e, 0x2b, 0x34].pack('C*').freeze
      PARTITION = ['060e2b34020501010d01020101'].pack('H*').freeze
      J2K = ['060e2b34010201010d010301150108'].pack('H*').freeze
      IAB = ['060e2b340102010d0d01030117010d'].pack('H*').freeze
      ATMOS = ['060e2b34010201050e090601000000'].pack('H*').freeze
      module_function

      def each_packet(path, on_open: nil)
        File.open(path, 'rb') do |io|
          on_open.call(io) if on_open
          size = io.stat.size
          probe = io.read([size, 65_552].min)
          start = probe.index(PARTITION)
          raise Error, 'MXF header partition not found within the permitted run-in' unless start && start <= 65_536
          offset = start
          while offset < size
            io.seek(offset)
            key = io.read(16)
            raise Error, "Truncated or invalid KLV key at byte #{offset}" unless key&.bytesize == 16 && key.start_with?(PREFIX)
            first = io.read(1)&.unpack1('C')
            raise Error, "Missing BER length at byte #{offset + 16}" unless first
            if first < 128
              length = first
            else
              count = first & 127
              raise Error, "Invalid BER length width #{count} at byte #{offset + 16}" unless count.between?(1, 8)
              bytes = io.read(count)
              raise Error, 'Truncated BER length' unless bytes&.bytesize == count
              length = bytes.bytes.reduce(0) { |n, byte| (n << 8) | byte }
            end
            value_offset = io.pos
            raise Error, "KLV at byte #{offset} extends beyond the file" if length > size - value_offset
            yield io, key, value_offset, length
            offset = value_offset + length
          end
        end
      end

      def kind(key)
        prefix = key.byteslice(0, 15)
        return :jpeg2000 if prefix == J2K
        return :iab if [IAB, ATMOS].include?(prefix)
        nil
      end
    end
  end
end
