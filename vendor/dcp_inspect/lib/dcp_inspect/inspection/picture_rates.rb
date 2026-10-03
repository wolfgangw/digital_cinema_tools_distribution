# frozen_string_literal: true
require_relative 'timing'
require_relative 'vocabulary'

module DcpInspect
  module Inspection
    # Delivery compatibility is distinct from rational timing consistency. This
    # checks known baseline profiles; it is not a validator for every AFR/HFR or
    # archival profile. In particular, do not apply JPEG2000 rules to MPEG2.
    module PictureRates
      module_function
      def findings(meta, composition_type:, stereoscopic:)
        rate = Timing.rate(meta['EditRate'] || meta['SampleRate'])
        sample = Timing.rate(meta['SampleRate'] || meta['EditRate'])
        return [[:error, 'Invalid picture EditRate or SampleRate']] unless rate && sample
        result = []
        expected = rate * (stereoscopic ? 2 : 1)
        if sample != expected
          result << [:error, "Picture SampleRate #{Timing.format_rate(sample)} must equal #{stereoscopic ? 'twice the per-eye' : 'the'} EditRate #{Timing.format_rate(rate)}"]
        end
        interop = composition_type == 'Interop' && meta['Label Set Type'] == 'MXF Interop'
        case meta['EssenceType']
        when Vocabulary::Mpeg2
          unless interop && !stereoscopic && [Rational(24000, 1001), Rational(24)].include?(rate)
            result << [:error, "MPEG2 picture rate #{Timing.format_rate(rate)} is outside the legacy Interop MPEG2 delivery profile (monoscopic 24000/1001 or 24 fps)"]
          end
        when Vocabulary::Pictures, Vocabulary::Stereoscopic_pictures
          if rate.denominator != 1
            result << [:error, "JPEG2000 picture rate #{Timing.format_rate(rate)} is incompatible with standard cinema delivery rates (ST 429-2 / Interop JPEG2000); fractional video rates such as 24000/1001 are not cinema delivery rates"]
          elsif interop
            baseline = stereoscopic ? [24] : [24, 48]
            unless baseline.include?(rate)
              result << [:hint, "Interop JPEG2000 picture rate #{Timing.format_rate(rate)} requires explicit target-system support; outside the conventional #{stereoscopic ? '24 fps per-eye' : '24/48 fps'} delivery baseline"]
            end
          elsif composition_type == 'SMPTE' && meta['Label Set Type'] == 'SMPTE'
            width, height = Timing.units(meta['StoredWidth']), Timing.units(meta['StoredHeight'])
            two_k = width && height && width.between?(1, 2048) && height.between?(1, 1080)
            four_k = width && height && width.between?(1, 4096) && height.between?(1, 2160)
            baseline = stereoscopic ? (two_k && rate == 24) : ((two_k && [24,25,30,48,50,60].include?(rate)) || (four_k && [24,25,30].include?(rate)))
            unless baseline
              result << [:hint, "SMPTE JPEG2000 #{meta['StoredWidth']}x#{meta['StoredHeight']} picture rate #{Timing.format_rate(rate)}#{stereoscopic ? ' per eye' : ''} is outside the ST 429-2 baseline; additional-frame-rate/HFR/archival profile and target-system compatibility remain unchecked"]
            end
          else
            result << [:hint, 'Picture-rate delivery profile unchecked: CPL and MXF format is unknown or mixed']
          end
        else
          result << [:hint, 'Picture-rate delivery compatibility unchecked: unrecognized picture essence']
        end
        result
      end
    end
  end
end
