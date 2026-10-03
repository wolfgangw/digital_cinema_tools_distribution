# frozen_string_literal: true
require_relative 'timing'

module DcpInspect
  module Inspection
    module PcmLayout
      # Registered MCA dictionary IDs (AS-DCP MDD), not MCATagSymbol guesses.
      ROLES = %w[L R C LFE Ls Rs Lss Rss Lrs Rrs Lc Rc Cs HI VIN FSKSync].each_with_index.to_h do |role, index|
        [format('060e2b340401010d030201%02x00000000', index + 1), role]
      end.merge({
        '060e2b34040101050e09010104030000' => 'Ltfs', '060e2b34040101050e09010104040000' => 'Rtfs',
        '060e2b34040101050e09010104070000' => 'Ltrs', '060e2b34040101050e09010104080000' => 'Rtrs'
      }).freeze
      GROUPS = {
        '060e2b340401010d0302020100000000' => %w[L R C LFE Ls Rs],
        '060e2b340401010d0302020200000000' => %w[L R C LFE Lss Rss Lrs Rrs],
        '060e2b340401010d0302020300000000' => %w[L R C LFE Ls Rs Lc Rc],
        '060e2b340401010d0302020400000000' => %w[L R C LFE Lss Rss Cs],
        '060e2b340401010d0302020500000000' => %w[C],
        '060e2b34040101050e09010105020000' => %w[L R C LFE Ls Rs Ltfs Rtfs Ltrs Rtrs]
      }.freeze
      FFMPEG = { 'L' => 'FL', 'R' => 'FR', 'C' => 'FC', 'LFE' => 'LFE', 'Ls' => 'SL', 'Rs' => 'SR',
        'Lss' => 'SL', 'Rss' => 'SR', 'Lrs' => 'BL', 'Rrs' => 'BR', 'Lc' => 'FLC', 'Rc' => 'FRC',
        'Cs' => 'BC', 'Ltfs' => 'TFL', 'Rtfs' => 'TFR', 'Ltrs' => 'TBL', 'Rtrs' => 'TBR' }.freeze
      STATIC = {
        1 => %w[L R C LFE Ls Rs HI VIN], 2 => ['L', 'R', 'C', 'LFE', 'Ls', 'Rs', 'Cs', nil, 'HI', 'VIN'],
        3 => %w[L R C LFE Ls Rs Lc Rc HI VIN], 5 => %w[L R C LFE Lss Rss Lrs Rrs HI VIN],
        4 => ['L', 'R', 'C', 'LFE', 'Ls', 'Rs', 'HI', 'VIN', nil, nil, 'Lrs', 'Rrs', nil, 'FSKSync', nil, nil]
      }.freeze
      module_function
      def ul(value) = value.to_s.delete('.').downcase
      def parse_mca(text)
        blocks = []
        current = nil
        text.each_line do |line|
          if (match = /\A[0-9a-f.]+\s+len:.*\(([^)]+)\)/i.match(line))
            current = { type: match[1] }
            blocks << current
          elsif current && (match = /^\s+(\w+)\s*=\s*(.*?)\s*$/.match(line))
            current[match[1]] = match[2]
          end
        end
        blocks
      end
      def resolve(meta, header = nil)
        count = Timing.units(meta['ChannelCount'])
        return { skipped: 'Invalid PCM channel count' } unless count && count.between?(1, 16)
        format = Timing.units(meta['ChannelFormat'])
        source = "SMPTE channel configuration #{format}"
        if format == 6
          blocks = parse_mca(header.to_s)
          groups = blocks.select { |b| b[:type] == 'SoundfieldGroupLabelSubDescriptor' }
          labels = blocks.select { |b| b[:type] == 'AudioChannelLabelSubDescriptor' }
          group = groups.first
          expected = group && GROUPS[ul(group['MCALabelDictionaryID'])]
          return { skipped: 'MCA programme layout is incomplete or unsupported' } unless groups.size == 1 && expected && group['MCALinkID']
          roles = Array.new(count)
          labels.each do |label|
            index = Timing.units(label['MCAChannelID'])
            role = ROLES[ul(label['MCALabelDictionaryID'])]
            return { skipped: 'MCA channel IDs/roles are missing, duplicated, or unsupported' } unless index && index.between?(1, count) && role && roles[index - 1].nil?
            if FFMPEG.key?(role) && label['SoundfieldGroupLinkID'] != group['MCALinkID']
              return { skipped: 'MCA programme channel is not linked to the soundfield group' }
            end
            roles[index - 1] = role
          end
          actual = roles.select { |role| FFMPEG.key?(role) }
          return { skipped: 'MCA programme channels do not match their declared soundfield' } unless actual.sort == expected.sort && roles.all?
          source = 'MCA dictionary IDs and soundfield links'
        elsif format == 0
          return { skipped: 'Unlabelled channel layout is ambiguous beyond eight channels' } if count > 8
          roles = count == 1 ? ['C'] : count == 2 ? %w[L R] : STATIC[1]
          source = 'Conventional unlabelled PCM mapping (inferred)'
        else
          roles = STATIC[format]
          return { skipped: 'Unknown PCM channel configuration' } unless roles
          return { skipped: 'PCM channel count exceeds its declared configuration' } if count > roles.size
          source = 'RDD 52 / ISDCF wild-track operational mapping (inferred)' if format == 4
        end
        map = roles.take(count).each_with_index.filter_map { |role, index| [FFMPEG[role], index] if FFMPEG[role] }
        return { skipped: 'No comparable programme channels' } if map.empty? || map.map(&:first).uniq.size != map.size
        { map: map, source: source, excluded_channels: (0...count).to_a - map.map(&:last) }
      end
      def pan(layout)
        'pan=' + layout[:map].map(&:first).join('+') + '|' + layout[:map].map { |role, index| "#{role}=c#{index}" }.join('|')
      end
    end
  end
end
