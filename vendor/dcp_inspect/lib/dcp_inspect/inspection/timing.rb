# frozen_string_literal: true

module DcpInspect
  module Inspection
    module Timing
      module_function

      def rate(value)
        match = /\A\s*(\d+)(?:\s+|\s*\/\s*)(\d+)\s*\z/.match(value.to_s)
        return nil unless match && match[1].to_i.positive? && match[2].to_i.positive?

        Rational(match[1].to_i, match[2].to_i)
      end

      def format_rate(value)
        return '[invalid rate]' unless value && value.positive?
        rate = value.to_r
        rate.denominator == 1 ? "#{rate.numerator} fps" : "#{rate} (≈#{format('%.3f', rate)}) fps"
      end

      def units(value)
        text = value.to_s.strip
        text.match?(/\A\d+\z/) ? text.to_i : nil
      end

      # Formatting cannot turn a valid integer duration into an exception.
      # Fractional edit rates have no unambiguous integer-fps timecode display.
      def format_units(value, edit_rate)
        count = units(value)
        return '[invalid timing]' unless count && edit_rate && edit_rate.positive?
        rate = edit_rate.to_r
        if rate.denominator != 1
          return "#{count} edit units @ #{rate} fps (#{format('%.3f', count / rate)} s)"
        end

        seconds, frames = count.divmod(rate.numerator)
        minutes, seconds = seconds.divmod(60)
        hours, minutes = minutes.divmod(60)
        format('%02d:%02d:%02d:%02d', hours, minutes, seconds, frames)
      end
    end
  end
end
