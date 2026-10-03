# frozen_string_literal: true
require_relative 'iab'
require_relative 'jpeg2000_headers'

module DcpInspect
  module Inspection
    class Runtime
      module MediaInspection
        def inspect_media_headers(path, meta)
          kind = case meta['EssenceType']
          when MStr::Pictures, MStr::Stereoscopic_pictures then :jpeg2000
          when MStr::Atmos then :iab
          end
          return nil unless kind
          @media_inspections ||= {}
          @media_inspections[path] ||= begin
            if meta['EncryptedEssence'] == 'Yes'
              { kind: kind, skipped: 'Encrypted essence: media headers/frames not inspected without a key' }
            else
              @logger.info "Inspecting #{kind == :iab ? 'IAB/Atmos metadata' : 'JPEG2000 headers'}: #{File.basename(path)}"
              progress = lambda do |frame|
                @logger.cr "#{kind}: #{frame} #{kind == :iab ? 'frames' : 'codestreams'} checked" if (frame % 1000).zero?
              end
              data = kind == :iab ? Iab.inspect_track(path, meta, &progress) : Jpeg2000Headers.inspect_track(path, meta, &progress)
              { kind: kind, data: data }
            end
          end
        end

        def media_header_report(result)
          return result[:skipped] if result[:skipped]
          data = result[:data]
          if result[:kind] == :iab
            range = ->(key) do
              value = data[key]
              value ? (value[:min] == value[:max] ? value[:min].to_s : "#{value[:min]}–#{value[:max]}") : 'unknown'
            end
            "IAB/Atmos: #{data[:parsed_frames]}/#{data[:frames]} frames parsed; beds #{range.call(:beds)}, object definitions #{range.call(:objects)} per frame; top-level beds #{range.call(:top_level_beds)}, objects #{range.call(:top_level_objects)}. #{data[:scope]}"
          else
            "JPEG2000: #{data[:checked]}/#{data[:codestreams]} codestream headers checked. #{data[:scope]}"
          end
        end

        def record_media_headers(result, prefix, errors, hints, report, inspection_run, cpl_model)
          return false unless result
          summary = media_header_report(result)
          report << "#{prefix}: #{summary}"
          if result[:skipped]
            hints << "#{prefix}: #{summary}"
            status = :skipped
          else
            data = result[:data]
            data[:errors].each do |finding|
              at = finding[:first_frame] || finding[:first_codestream]
              message = "#{prefix}: #{result[:kind]}: #{finding[:message]} (#{finding[:count]} occurrences#{at ? "; first frame/codestream #{at}" : ''})"
              errors << message
            end
            partial = data[:unknown_elements]&.any? || data[:unchecked_overrides]&.any?
            hints << "#{prefix}: #{result[:kind]} contains elements/overrides outside this inspection's coverage" if partial
            if data[:unchecked_descriptor_fields]&.any?
              hints << "#{prefix}: MXF JPEG2000 descriptor/essence comparison unchecked for fields not exposed by metadata inspection: #{data[:unchecked_descriptor_fields].join(', ')}"
              partial = true
            end
            status = data[:errors].any? ? :error : partial ? :hint : :ok
          end
          inspection_run.add_check(cpl_model, result[:kind], status, "#{prefix}: #{summary}", result) if cpl_model
          status == :error
        end
      end
    end
  end
end
