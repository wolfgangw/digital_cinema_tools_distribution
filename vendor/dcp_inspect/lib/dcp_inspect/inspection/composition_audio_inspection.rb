# frozen_string_literal: true
require_relative 'composition_audio'

module DcpInspect
  module Inspection
    class Runtime
      module CompositionAudioInspection
        def composition_audio_measurement(references, reel_count, dict, timing_valid)
          return { skipped: 'Composition MainSound loudness not measured: invalid CPL timeline' } unless timing_valid
          sounds = references.select { |reference| reference[:kind] == 'MainSound' }
          unless sounds.size == reel_count && sounds.map { |s| s[:reel_no] }.uniq.size == reel_count
            return { skipped: 'Composition MainSound loudness not measured: every reel must have exactly one MainSound' }
          end
          segments = []
          mapping_sources = []
          layout = nil
          sounds.each do |sound|
            relative = dict && dict[sound[:id]]
            path = relative && package(relative)
            meta = path && File.file?(path) && inspect_mxf(path)
            return { skipped: 'Composition MainSound loudness not measured: an asset is unavailable or not PCM' } unless meta && meta['EssenceType'] == MStr::Audio
            return { skipped: 'Composition MainSound loudness not measured: encrypted PCM requires a key' } if meta['EncryptedEssence'] != 'No'
            header = nil
            if meta['ChannelFormat'] == '6'
              @mca_headers ||= {}
              header = (@mca_headers[path] ||= begin
                output, _error, status = Open3.capture3('asdcp-info', '-H', path)
                status.success? ? output : ''
              end)
            end
            current_layout = PcmLayout.resolve(meta, header)
            return { skipped: "Composition MainSound loudness not measured: #{current_layout[:skipped]}" } if current_layout[:skipped]
            rate = Timing.rate(meta['AudioSamplingRate'])
            edit_rate = Timing.rate(sound[:edit_rate_ratio])
            channels = Timing.units(meta['ChannelCount'])
            container = Timing.units(meta['ContainerDuration'])
            unless rate && rate.denominator == 1 && [48_000, 96_000].include?(rate.to_i) && edit_rate &&
                edit_rate == Timing.rate(meta['EditRate'] || meta['SampleRate']) && (rate / edit_rate).denominator == 1 &&
                meta['QuantizationBits'] == '24' && container && sound[:entry_point] >= 0 &&
                sound[:duration] && sound[:duration] > 0 && sound[:entry_point] + sound[:duration] <= container
              return { skipped: 'Composition MainSound loudness not measured: unsupported/inconsistent PCM geometry or playback window' }
            end
            segment = { path: path, entry: sound[:entry_point], duration: sound[:duration],
              samples_per_frame: (rate / edit_rate).to_i, channels: channels, sample_rate: rate.to_i }
            if layout && (layout[:map] != current_layout[:map] || segments.first.values_at(:channels, :sample_rate) != segment.values_at(:channels, :sample_rate))
              return { skipped: 'Composition MainSound loudness not measured: PCM format/programme mapping changes across reels' }
            end
            layout ||= current_layout
            mapping_sources << current_layout[:source]
            segments << segment
          end
          return { skipped: 'Composition contains no MainSound timeline' } if segments.empty?
          layout = layout.merge(source: mapping_sources.uniq.join('; '))
          samples = segments.sum { |segment| segment[:duration] * segment[:samples_per_frame] }
          if samples < segments.first[:sample_rate] * Rational(2, 5)
            return { skipped: 'Composition MainSound is shorter than the 400 ms integrated-loudness gate' }
          end
          @logger.info "Measuring composition MainSound loudness across #{segments.size} reels"
          last_percent = -1
          text = CompositionAudio.measure(segments, layout) do |written, total|
            percent = total > 0 ? written * 100 / total : 0
            if percent != last_percent
              @logger.cr "Composition MainSound loudness: #{percent}%"
              last_percent = percent
            end
          end
          stats = parse_ffmpeg_audio_analysis(text)
          unless stats[:integrated_lufs] && stats.dig(:pk_lev_db, :overall)
            raise AudioAnalysis::Error, 'ffmpeg returned no complete composition measurements'
          end
          stats.merge(scope: 'Continuous CPL MainSound programme channels only; IAB not rendered',
            channel_mapping: layout, reels: segments.size,
            samples: segments.sum { |s| s[:duration] * s[:samples_per_frame] },
            status: stats[:silent] ? 'SILENT' : 'MEASURED', role: :info, delta: nil)
        rescue AudioAnalysis::Error, SystemCallError => error
          { error: error.message }
        end

        def record_composition_audio(measurement, cpl_id, report, errors, hints, inspection_run, cpl_model)
          if measurement[:skipped]
            message, status = measurement[:skipped], :skipped
            hints << "CPL #{cpl_id}: #{message}"
          elsif measurement[:error]
            message, status = "Composition MainSound loudness failed: #{measurement[:error]}", :error
            errors << "CPL #{cpl_id}: #{message}"
          else
            level = measurement[:silent] ? 'silent' : format('%.1f LUFS integrated; %.1f LU LRA; %s dBFS true peak', measurement[:integrated_lufs], measurement[:lra_lu], measurement[:true_peak_dbfs])
            message, status = "Composition MainSound: #{level}. #{measurement[:scope]}. Mapping: #{measurement[:channel_mapping][:source]}", :info
          end
          report << message
          inspection_run.add_check(cpl_model, :composition_audio, status, message, measurement) if cpl_model
          status == :error
        end
      end
    end
  end
end
