# frozen_string_literal: true
require_relative 'timing'
require_relative 'vocabulary'

module DcpInspect
  module Inspection
    module ScreenAspectRatio
      INTEROP_SCOPE = Vocabulary::Interop_cpl + 'standard-aspectratio'
      # Conventional decimal ratios (e.g. 2.39 for 2048/858) are rounded to
      # two places. Compare exact rationals, with half a hundredth tolerance.
      TOLERANCE = Rational(1, 200)
      module_function
      def finding(node, meta, composition_type:)
        return nil unless node
        text = node.text.strip
        scope = node['scope']
        details = { declared: text, scope: scope, width: meta['StoredWidth'], height: meta['StoredHeight'] }
        if composition_type == 'Interop' && scope && scope != INTEROP_SCOPE
          return details.merge(message: "ScreenAspectRatio #{text.inspect} uses custom scope #{scope.inspect}; comparison unchecked")
        end
        declared = case composition_type
        when 'Interop'
          Rational(text) if text.match?(/\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)\z/)
        when 'SMPTE'
          Timing.rate(text)
        end
        unless declared && declared.positive?
          return details.merge(message: "ScreenAspectRatio #{text.inspect} cannot be compared as a positive #{composition_type == 'Interop' ? 'decimal' : 'rational'} ratio")
        end
        if [Vocabulary::Pictures, Vocabulary::Stereoscopic_pictures].include?(meta['EssenceType'])
          width, height = Timing.units(meta['StoredWidth']), Timing.units(meta['StoredHeight'])
          observed = Rational(width, height) if width&.positive? && height&.positive?
          basis = "stored picture dimensions #{meta['StoredWidth']}x#{meta['StoredHeight']}"
        elsif meta['EssenceType'] == Vocabulary::Mpeg2
          # MPEG2 need not have square samples. Do not mistake the raster ratio
          # for the intended display ratio.
          observed = Timing.rate(meta['AspectRatio'])
          basis = "MXF display AspectRatio #{meta['AspectRatio']}"
        end
        unless observed
          return details.merge(message: "ScreenAspectRatio #{text.inspect}: picture aspect evidence unavailable; comparison unchecked")
        end
        return nil if (declared - observed).abs <= TOLERANCE
        details.merge(observed_ratio: observed.to_s, basis: basis, tolerance: TOLERANCE.to_s,
          message: "ScreenAspectRatio #{text.inspect} differs from #{basis} (#{format('%.4f', observed)}). Review the informational declaration; active picture/padding has not been measured")
      end
    end
  end
end
