# frozen_string_literal: true

require "nokogiri"

module DcpInspect
  module XML
    class DocumentReader
      def initialize(logger:, mxf_inspector:)
        @logger = logger
        @mxf_inspector = mxf_inspector
      end

      def read_type(type, file, errors, error_status)
        document = parse(file)
        return [false, errors, error_status] unless document

        document.errors.each do |error|
          next if error.message.match?(/Start tag expected|Document is empty/)

          errors << "Syntax error ❌: #{file}: #{error}"
          error_status = true
          @logger.info(errors.last)
        end
        return [false, errors, error_status] unless document.errors.empty? && document.root&.node_name == type

        [document, errors, error_status]
      end

      def xml(file)
        document = parse(file)
        document&.root ? document : false
      end

      def asset_uuid(file)
        return nil unless File.exist?(file)

        document = xml(file)
        return @mxf_inspector.call(file)&.fetch('AssetUUID', nil) unless document

        document.remove_namespaces!
        id = document.xpath('/*/Id').first&.text
        id ||= document.xpath('//SubtitleID').text
        id = document.xpath('//MetadataID').text if id.empty?
        id = id.split(':', -1).last&.strip
        id unless id.nil? || id.empty?
      end

      def namespace_prefix(document, namespace)
        prefixes = document.collect_all_namespaces_href_keys[namespace]
        prefixes&.first || 'xmlns'
      end

      private

      def parse(file)
        Nokogiri::XML(File.open(file))
      rescue StandardError => error
        @logger.info "#{file}: #{error.message}"
        nil
      end
    end
  end
end
