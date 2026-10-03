# frozen_string_literal: true
require_relative 'timing'
require_relative 'pcm_layout'

module DcpInspect
  module Inspection
    module AudioChannels
      module_function

      # Container count is not a soundfield declaration. Interop's even-count
      # guidance is an ISDCF recommendation; ST 429-2 Annex A is normative.
      def findings(meta)
        count = Timing.units(meta['ChannelCount'])
        return [[:error, "Invalid MainSound ChannelCount #{meta['ChannelCount'].inspect}; expected a positive integer"]] unless count&.positive?
        findings = []
        if count > 16
          findings << [:error, "MainSound has #{count} channels; exceeds the supported 16-channel cinema PCM limit (ST 428-2 / DCI audio scope)"]
        end
        smpte = meta['Label Set Type'] == 'SMPTE'
        if count.odd?
          source = smpte ? 'ST 429-2 Annex A requires an even container channel count' : 'ISDCF Doc 4 recommends an even container channel count for Interop delivery'
          findings << [smpte ? :error : :hint, "MainSound has #{count} channels; #{source}. A silent padding channel may be needed"]
        end
        if smpte
          format = Timing.units(meta['ChannelFormat'])
          channels = PcmLayout::STATIC[format]
          if channels && count > channels.length
            findings << [:error, "MainSound has #{count} channels but SMPTE channel configuration #{format} defines only #{channels.length} (ST 429-2 Annex A)"]
          end
        end
        findings
      end
    end
  end
end
