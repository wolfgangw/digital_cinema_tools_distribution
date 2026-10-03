# frozen_string_literal: true
require_relative 'timing'
require_relative 'vocabulary'

module DcpInspect
  module Inspection
    module CompositionReporting
      module_function
      def sound(tracks, references, immersive_ids)
        pcm = tracks.select { |track| track[:essence] == Vocabulary::Audio }
        formats = pcm.map do |track|
          channels = Timing.units(track[:channels])
          bits = Timing.units(track[:bits])
          rate = Timing.rate(track[:sample_rate])
          sample = rate && rate.denominator == 1 ? format('%g kHz', rate / 1000) : 'sample rate unknown'
          "PCM #{channels&.positive? ? channels : '?'}ch container / #{sample} / #{bits&.positive? ? bits : '?'}-bit"
        end.uniq
        expected = references.count { |ref| ref[:kind] == 'MainSound' }
        missing = expected - pcm.size
        parts = formats.dup
        parts << 'no MainSound' if expected.zero?
        parts << "#{missing}/#{expected} MainSound references unavailable or not PCM" if missing.positive?
        parts << 'format changes across reels' if formats.size > 1
        parts << 'IAB/Atmos present' if immersive_ids.any?
        { text: "Sound: #{parts.join('; ')}", tracks: tracks,
          main_sound_references: expected, unavailable_main_sound_references: missing,
          immersive_asset_ids: immersive_ids.uniq }
      end

      def packages(packing_lists)
        packing_lists.uniq(&:id).map do |pkl|
          { pkl_id: pkl.id, listed_bytes: pkl.package_size_listed, available_bytes: pkl.package_size_actual }
        end
      end

      def package_text(packages)
        return 'PKL asset sizes: unavailable' if packages.empty?
        'PKL asset sizes: ' + packages.map do |pkg|
          size = ->(value) { value.nil? ? 'unknown' : value.to_k }
          "#{pkg[:pkl_id]}: #{size.call(pkg[:available_bytes])} present / #{size.call(pkg[:listed_bytes])} listed"
        end.join('; ')
      end
    end
  end
end
