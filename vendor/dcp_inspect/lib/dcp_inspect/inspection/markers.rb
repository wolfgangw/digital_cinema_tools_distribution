# frozen_string_literal: true
require_relative 'timing'

module DcpInspect
  module Inspection
    module Markers
      LABELS = %w[FFOC LFOC FFTC LFTC FFOI LFOI FFEC LFEC FFOB LFOB FFMC LFMC].freeze
      SCOPES = %w[http://www.smpte-ra.org/schemas/429-7/2006/CPL#standard-markers http://www.digicine.com/PROTO-ASDCP-CPL-20040511#standard-markers].freeze
      module_function

      def text(node, name)
        node.at_xpath("./*[local-name()='#{name}']")&.text
      end

      def timeline(asset)
        rate = Timing.rate(text(asset, 'EditRate'))
        intrinsic = Timing.units(text(asset, 'IntrinsicDuration'))
        entry = Timing.units(text(asset, 'EntryPoint') || '0')
        duration = Timing.units(text(asset, 'Duration') || (intrinsic && entry && intrinsic - entry).to_s)
        [rate, intrinsic, entry, duration]
      end

      def inspect(reels)
        errors, records = [], []
        elapsed = Rational(0)
        reels.each_with_index do |reel, index|
          assets = reel.xpath("./*[local-name()='AssetList']/*")
          tracks = assets.reject { |a| %w[MainMarkers CompositionMetadataAsset].include?(a.name) }
          spans = tracks.map do |track|
            rate, intrinsic, entry, duration = timeline(track)
            duration / rate if rate && intrinsic && entry && duration && duration.positive? && entry + duration <= intrinsic
          end
          reel_seconds = spans.any? && spans.all? && spans.uniq.size == 1 ? spans.first : nil
          assets.select { |a| a.name == 'MainMarkers' }.each do |asset|
            prefix = "Reel #{index + 1} MainMarkers"
            rate, intrinsic, entry, duration = timeline(asset)
            valid = rate && intrinsic && entry && duration && entry + duration <= intrinsic
            errors << "#{prefix}: invalid EditRate, IntrinsicDuration, EntryPoint or Duration" unless valid
            if valid && reel_seconds && duration / rate > reel_seconds
              errors << "#{prefix}: marker playback duration exceeds reel duration"
            end
            offsets = []
            asset.xpath("./*[local-name()='MarkerList']/*[local-name()='Marker']").each do |marker|
              label_node = marker.at_xpath("./*[local-name()='Label']")
              label = label_node&.text.to_s.strip
              scope = label_node&.[]('scope')
              standard = scope.nil? || SCOPES.include?(scope)
              offset = Timing.units(text(marker, 'Offset'))
              errors << "#{prefix}: unknown standard marker #{label.inspect}" if standard && !LABELS.include?(label)
              errors << "#{prefix}: marker #{label} has invalid Offset" unless offset
              errors << "#{prefix}: marker #{label} Offset #{offset} exceeds IntrinsicDuration #{intrinsic}" if offset && intrinsic && offset > intrinsic
              offsets << offset if offset
              # ST 429-7 defines offsets on the marker asset's native timeline.
              # EntryPoint maps that timeline to the reel; trimmed markers are
              # retained for inspection but excluded from composition checks.
              active = valid && offset && offset >= entry && offset <= entry + duration
              position = active && elapsed ? elapsed + (offset - entry) / rate : nil
              if active && reel_seconds && (offset - entry) / rate > reel_seconds
                errors << "#{prefix}: marker #{label} lies beyond the reel"
              end
              records << { label: label, scope: scope, standard: standard, reel: index + 1,
                offset: offset, active: !!active, seconds: position&.to_s }
            end
            # Existing packages use both end-boundary and last-frame conventions.
            if intrinsic && offsets.any? && ![intrinsic, intrinsic - 1].include?(offsets.max)
              errors << "#{prefix}: last marker Offset #{offsets.max} does not correspond to IntrinsicDuration #{intrinsic}"
            end
          end
          elapsed = elapsed && reel_seconds ? elapsed + reel_seconds : nil
        end
        standard = records.select { |r| r[:standard] && r[:active] && r[:seconds] && LABELS.include?(r[:label]) }.group_by { |r| r[:label] }
        standard.each { |label, entries| errors << "Duplicate standard marker #{label} in composition" if entries.size > 1 }
        positions = standard.select { |_label, entries| entries.size == 1 }.transform_values { |entries| Rational(entries.first[:seconds]) }
        LABELS.each_slice(2) do |first, last|
          if positions[first] && positions[last] && positions[first] > positions[last]
            errors << "Marker #{first} occurs after #{last}"
          end
        end
        positions.each do |label, position|
          if positions['FFOC'] && position < positions['FFOC'] || positions['LFOC'] && position > positions['LFOC']
            errors << "Marker #{label} lies outside composition display boundaries"
          end
        end
        %w[FFMC LFMC].each do |label|
          next unless positions[label]
          if positions['FFEC'] && positions[label] < positions['FFEC'] || positions['LFEC'] && positions[label] > positions['LFEC']
            errors << "Marker #{label} lies outside end credits"
          end
        end
        { errors: errors, records: records }
      end
    end
  end
end
