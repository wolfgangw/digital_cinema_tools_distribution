# frozen_string_literal: true

module DcpInspect
  module Inspection
    # Pure checks over observed evidence. Do not infer essence from filenames or
    # use a declaration as evidence that the declaration itself is correct.
    module MetadataChecks
      INTEROP_TYPES = {
        picture: "application/x-smpte-mxf;asdcpkind=picture",
        sound: "application/x-smpte-mxf;asdcpkind=sound",
        cpl: "text/xml;asdcpkind=cpl", subtitle: "text/xml;asdcpkind=subtitle",
        font: "application/ttf", png: "image/png"
      }.freeze

      module_function

      def normalize_media_type(value)
        type, *parameters = value.to_s.split(";")
        ([type.to_s.strip.downcase] + parameters.map { |p| p.strip.downcase.gsub(/\s*=\s*/, "=") }.sort).join(";")
      end

      def type_errors(format, declared, kind, mxf: false)
        return [] unless kind

        expected = if format == "Interop"
          INTEROP_TYPES[kind]
        elsif format == "SMPTE"
          mxf ? "application/mxf" : (kind == :cpl ? "text/xml" : nil)
        end
        return [] unless expected
        return [] if normalize_media_type(declared) == expected

        ["Type #{declared.inspect} does not match inspected #{kind} asset; expected #{expected} for #{format} PKL"]
      end

      # Exact XML text equality: preserve case and whitespace. Re-encountering
      # the same CPL UUID through multiple PKLs is not a duplicate title.
      def duplicate_titles(titles_by_id)
        titles_by_id.group_by { |_id, title| title }.filter_map do |title, entries|
          next if title.to_s.strip.empty?
          ids = entries.map(&:first).uniq { |id| id.downcase }
          { title: title, cpl_ids: ids } if ids.size > 1
        end
      end

      def duplicate_ids(nodes)
        nodes.map { |node| node.text.strip.sub(/\Aurn:uuid:/i, "").downcase }
          .reject(&:empty?).tally.select { |_id, count| count > 1 }.keys
      end
    end
  end
end
