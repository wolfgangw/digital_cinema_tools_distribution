# frozen_string_literal: true

require "nokogiri"

module DcpInspect
  module XML
    class SchemaStore
      CATALOG_MUTEX = Mutex.new

      attr_reader :directory

      def initialize(directory = DcpInspect.xsd_dir)
        @directory = File.expand_path(directory)
        @catalog_path = load_catalog
      end

      def validate(document, schema_filename)
        schema(schema_filename).validate(document)
      end

      def schema(schema_filename)
        @schemas ||= {}
        @schemas[schema_filename] ||= begin
          CATALOG_MUTEX.synchronize do
            previous_catalog = ENV['XML_CATALOG_FILES']
            ENV['XML_CATALOG_FILES'] = @catalog_path
            begin
              Nokogiri::XML::Schema(File.open(File.join(directory, schema_filename)))
            ensure
              previous_catalog ? ENV['XML_CATALOG_FILES'] = previous_catalog : ENV.delete('XML_CATALOG_FILES')
            end
          end
        end
      end

      private

      def load_catalog
        path = File.join(directory, 'catalog.xml')
        raise DcpInspect::Inspection::Error.new("Local XML Catalog #{path} not found", 5) unless File.file?(path)

        path
      end
    end
  end
end
