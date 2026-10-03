# frozen_string_literal: true

module DcpInspect
  module Model
    class InspectionEvent
      attr_reader :kind, :subject, :data, :created_at

      def initialize( kind, subject, data = {} )
        @kind = kind
        @subject = subject
        @data = data
        @created_at = Time.now
      end

      def to_h
        {
          :kind => @kind,
          :subject_type => @subject.class.name,
          :subject_id => @subject.respond_to?( :id ) ? @subject.id : nil,
          :data => @data,
          :created_at => @created_at.to_s
        }
      end
    end


    class CheckResult
      attr_reader :kind, :status, :message, :details, :created_at

      def initialize( kind, status, message = nil, details = {} )
        @kind = kind
        @status = status
        @message = message
        @details = details
        @created_at = Time.now
      end

      def to_h
        {
          :kind => @kind,
          :status => @status,
          :message => @message,
          :details => @details,
          :created_at => @created_at.to_s
        }
      end
    end


    class InspectionRun
      attr_reader :root_path, :packages, :assetmaps, :packing_lists, :compositions, :assets, :events
      attr_accessor :renderer

      def initialize( root_path )
        @root_path = root_path
        @packages = []
        @packages_by_base = {}
        @assetmaps = {}
        @packing_lists = {}
        @compositions = {}
        @assets = {}
        @events = []
      end

      def package( base_path )
        base = base_path.nil? || base_path.empty? ? '.' : base_path
        unless @packages_by_base[ base ]
          @packages_by_base[ base ] = DcpPackage.new( self, base )
          @packages << @packages_by_base[ base ]
        end
        @packages_by_base[ base ]
      end

      def assetmap( id, attrs = {} )
        key = model_key( id, attrs[ :path ] )
        am = ( @assetmaps[ key ] ||= AssetMap.new( self, key ) )
        am.update( attrs )
        if attrs[ :base ]
          pkg = package( attrs[ :base ] )
          am.package = pkg
          pkg.add_assetmap( am )
        end
        event( :assetmap, am, attrs )
        am
      end

      def asset( id, attrs = {} )
        key = model_key( id, attrs[ :assetmap_path ] || attrs[ :packing_list_path ] )
        a = ( @assets[ key ] ||= DcpAsset.new( self, key ) )
        a.update( attrs )
        if attrs[ :assetmap_id ] && @assetmaps[ attrs[ :assetmap_id ] ]
          am = @assetmaps[ attrs[ :assetmap_id ] ]
          a.assetmap = am
          am.add_asset( a )
        end
        if attrs[ :packing_list_id ] && @packing_lists[ attrs[ :packing_list_id ] ]
          pkl = @packing_lists[ attrs[ :packing_list_id ] ]
          a.add_packing_list( pkl )
          pkl.add_asset( a )
        end
        event( :asset, a, attrs )
        a
      end

      def packing_list( id, attrs = {} )
        key = model_key( id, attrs[ :path ] )
        pkl = ( @packing_lists[ key ] ||= PackingList.new( self, key ) )
        pkl.update( attrs )
        if attrs[ :assetmap_id ] && @assetmaps[ attrs[ :assetmap_id ] ]
          am = @assetmaps[ attrs[ :assetmap_id ] ]
          pkl.assetmap = am
          am.add_packing_list( pkl )
        end
        event( :packing_list, pkl, attrs )
        pkl
      end

      def composition( id, attrs = {} )
        key = model_key( id, attrs[ :path ] )
        cpl = ( @compositions[ key ] ||= CompositionPlaylist.new( self, key ) )
        cpl.update( attrs )
        if attrs[ :packing_list_id ] && @packing_lists[ attrs[ :packing_list_id ] ]
          pkl = @packing_lists[ attrs[ :packing_list_id ] ]
          cpl.add_packing_list( pkl )
          pkl.add_composition( cpl )
        end
        event( :composition, cpl, attrs )
        cpl
      end

      def reel_asset( cpl_id, reel_no, asset_id, attrs = {} )
        cpl = composition( cpl_id )
        reel = cpl.reel( reel_no )
        a = asset( asset_id )
        reel_asset = reel.asset( asset_id, attrs.merge( :asset => a ) )
        a.add_reel_reference( reel_asset )
        event( :reel_asset, reel_asset, attrs )
        reel_asset
      end

      def event( kind, subject, data = {} )
        inspection_event = InspectionEvent.new( kind, subject, data )
        @events << inspection_event
        @renderer.model_event( inspection_event ) if @renderer && @renderer.respond_to?( :model_event )
        inspection_event
      end

      def add_check( subject, kind, status, message = nil, details = {} )
        result = CheckResult.new( kind, status, message, details )
        subject.add_check( result ) if subject.respond_to?( :add_check )
        event( :check, subject, :kind => kind, :status => status, :message => message )
        result
      end

      def to_h
        {
          :root_path => @root_path,
          :packages => @packages.map { |package| package.to_h },
          :assetmaps => @assetmaps.values.map { |assetmap| assetmap.to_h },
          :packing_lists => @packing_lists.values.map { |packing_list| packing_list.to_h },
          :compositions => @compositions.values.map { |composition| composition.to_h },
          :assets => @assets.values.map { |asset| asset.to_h },
          :events => @events.map { |event| event.to_h }
        }
      end

      private

      def model_key( id, fallback )
        id.nil? || id.to_s.empty? ? fallback : id
      end
    end


    class DcpPackage
      attr_reader :run, :base_path, :assetmaps

      def initialize( run, base_path )
        @run = run
        @base_path = base_path
        @assetmaps = []
      end

      def add_assetmap( assetmap )
        @assetmaps << assetmap unless @assetmaps.include?( assetmap )
      end

      def to_h
        {
          :base_path => @base_path,
          :assetmap_ids => @assetmaps.map { |assetmap| assetmap.id }
        }
      end
    end


    class ModelNode
      attr_reader :run, :id, :checks

      def initialize( run, id )
        @run = run
        @id = id
        @checks = []
      end

      def add_check( result )
        @checks << result
      end

      def update_common( attrs )
        @path = attrs[ :path ] if attrs.key?( :path )
        @absolute_path = attrs[ :absolute_path ] if attrs.key?( :absolute_path )
        @present = attrs[ :present ] if attrs.key?( :present )
        @namespace = attrs[ :namespace ] if attrs.key?( :namespace )
        @schema_status = attrs[ :schema_status ] if attrs.key?( :schema_status )
        @signature_status = attrs[ :signature_status ] if attrs.key?( :signature_status )
      end

      def checks_to_h
        @checks.map { |check| check.to_h }
      end
    end


    class AssetMap < ModelNode
      attr_reader :assets, :packing_lists
      attr_accessor :package, :path, :absolute_path, :present, :namespace, :schema_status, :asset_count

      def initialize( run, id )
        super
        @assets = []
        @packing_lists = []
      end

      def update( attrs )
        update_common( attrs )
        @asset_count = attrs[ :asset_count ] if attrs.key?( :asset_count )
      end

      def add_asset( asset )
        @assets << asset unless @assets.include?( asset )
      end

      def add_packing_list( pkl )
        @packing_lists << pkl unless @packing_lists.include?( pkl )
      end

      def to_h
        {
          :id => @id,
          :path => @path,
          :absolute_path => @absolute_path,
          :present => @present,
          :namespace => @namespace,
          :schema_status => @schema_status,
          :asset_count => @asset_count,
          :package_base => @package ? @package.base_path : nil,
          :asset_ids => @assets.map { |asset| asset.id },
          :packing_list_ids => @packing_lists.map { |pkl| pkl.id },
          :checks => checks_to_h
        }
      end
    end


    class PackingList < ModelNode
      attr_reader :assets, :compositions
      attr_accessor :assetmap, :path, :absolute_path, :present, :namespace, :schema_status,
                    :signature_status, :annotation, :asset_count, :package_size_listed,
                    :package_size_actual

      def initialize( run, id )
        super
        @assets = []
        @compositions = []
      end

      def update( attrs )
        update_common( attrs )
        @annotation = attrs[ :annotation ] if attrs.key?( :annotation )
        @asset_count = attrs[ :asset_count ] if attrs.key?( :asset_count )
        @package_size_listed = attrs[ :package_size_listed ] if attrs.key?( :package_size_listed )
        @package_size_actual = attrs[ :package_size_actual ] if attrs.key?( :package_size_actual )
      end

      def add_asset( asset )
        @assets << asset unless @assets.include?( asset )
      end

      def add_composition( composition )
        @compositions << composition unless @compositions.include?( composition )
      end

      def to_h
        {
          :id => @id,
          :path => @path,
          :absolute_path => @absolute_path,
          :present => @present,
          :namespace => @namespace,
          :schema_status => @schema_status,
          :signature_status => @signature_status,
          :annotation => @annotation,
          :asset_count => @asset_count,
          :package_size_listed => @package_size_listed,
          :package_size_actual => @package_size_actual,
          :assetmap_id => @assetmap ? @assetmap.id : nil,
          :asset_ids => @assets.map { |asset| asset.id },
          :composition_ids => @compositions.map { |composition| composition.id },
          :checks => checks_to_h
        }
      end
    end


    class CompositionPlaylist < ModelNode
      def completeness_status
        return :pending if complete.nil?
        return :complete if complete == true || complete.to_s.start_with?('Composition complete')
        return :external if complete.to_s.include?('Supplemental/VF/External')
        return :warning if complete.to_s.start_with?('Composition warning')

        :incomplete
      end

      attr_reader :packing_lists, :reels
      attr_accessor :path, :absolute_path, :present, :namespace, :schema_status,
                    :signature_status, :type, :title, :language, :annotation,
                    :content_kind, :issue_date, :issuer, :creator, :summary, :summary_details,
                    :complete

      def initialize( run, id )
        super
        @packing_lists = []
        @reels = []
        @reels_by_number = {}
      end

      def update( attrs )
        update_common( attrs )
        @type = attrs[ :type ] if attrs.key?( :type )
        @title = attrs[ :title ] if attrs.key?( :title )
        @language = attrs[ :language ] if attrs.key?( :language )
        @annotation = attrs[ :annotation ] if attrs.key?( :annotation )
        @content_kind = attrs[ :content_kind ] if attrs.key?( :content_kind )
        @issue_date = attrs[ :issue_date ] if attrs.key?( :issue_date )
        @issuer = attrs[ :issuer ] if attrs.key?( :issuer )
        @creator = attrs[ :creator ] if attrs.key?( :creator )
        @summary = attrs[ :summary ] if attrs.key?( :summary )
        @summary_details = attrs[:summary_details] if attrs.key?(:summary_details)
        @complete = attrs[ :complete ] if attrs.key?( :complete )
      end

      def add_packing_list( pkl )
        @packing_lists << pkl unless @packing_lists.include?( pkl )
      end

      def reel( number )
        unless @reels_by_number[ number ]
          @reels_by_number[ number ] = Reel.new( self, number )
          @reels << @reels_by_number[ number ]
        end
        @reels_by_number[ number ]
      end

      def to_h
        {
          :id => @id,
          :path => @path,
          :absolute_path => @absolute_path,
          :present => @present,
          :namespace => @namespace,
          :schema_status => @schema_status,
          :signature_status => @signature_status,
          :type => @type,
          :title => @title,
          :language => @language,
          :annotation => @annotation,
          :content_kind => @content_kind,
          :issue_date => @issue_date,
          :issuer => @issuer,
          :creator => @creator,
          :summary => @summary,
          :summary_details => @summary_details,
          :complete => @complete,
          :packing_list_ids => @packing_lists.map { |pkl| pkl.id },
          :reels => @reels.map { |reel| reel.to_h },
          :checks => checks_to_h
        }
      end
    end


    class Reel
      attr_reader :composition, :number, :assets

      def initialize( composition, number )
        @composition = composition
        @number = number
        @assets = []
        @assets_by_key = {}
      end

      def asset( asset_id, attrs = {} )
        key = [ asset_id, attrs[ :kind ] ].compact.join( '|' )
        unless @assets_by_key[ key ]
          @assets_by_key[ key ] = ReelAsset.new( self, asset_id )
          @assets << @assets_by_key[ key ]
        end
        @assets_by_key[ key ].update( attrs )
        @assets_by_key[ key ]
      end

      def to_h
        {
          :number => @number,
          :assets => @assets.map { |asset| asset.to_h }
        }
      end
    end


    class ReelAsset
      attr_reader :reel, :id
      attr_accessor :asset, :kind, :intrinsic_duration, :entry_point, :duration,
                    :edit_rate, :key_id, :details, :resolved

      def initialize( reel, id )
        @reel = reel
        @id = id
      end

      def update( attrs )
        @asset = attrs[ :asset ] if attrs.key?( :asset )
        @kind = attrs[ :kind ] if attrs.key?( :kind )
        @intrinsic_duration = attrs[ :intrinsic_duration ] if attrs.key?( :intrinsic_duration )
        @entry_point = attrs[ :entry_point ] if attrs.key?( :entry_point )
        @duration = attrs[ :duration ] if attrs.key?( :duration )
        @edit_rate = attrs[ :edit_rate ] if attrs.key?( :edit_rate )
        @key_id = attrs[ :key_id ] if attrs.key?( :key_id )
        @details = attrs[ :details ] if attrs.key?( :details )
        @resolved = attrs[ :resolved ] if attrs.key?( :resolved )
      end

      def to_h
        {
          :id => @id,
          :asset_id => @asset ? @asset.id : @id,
          :kind => @kind,
          :intrinsic_duration => @intrinsic_duration,
          :entry_point => @entry_point,
          :duration => @duration,
          :edit_rate => @edit_rate,
          :key_id => @key_id,
          :details => @details,
          :resolved => @resolved
        }
      end
    end


    class DcpAsset < ModelNode
      attr_reader :packing_lists, :reel_references
      attr_accessor :assetmap, :assetmap_path, :packing_list_path, :absolute_path,
                    :present, :type, :size_listed, :size_actual, :hash_expected,
                    :hash_digest, :hash_status

      def initialize( run, id )
        super
        @packing_lists = []
        @reel_references = []
      end

      def update( attrs )
        @assetmap_path = attrs[ :assetmap_path ] if attrs.key?( :assetmap_path )
        @packing_list_path = attrs[ :packing_list_path ] if attrs.key?( :packing_list_path )
        @absolute_path = attrs[ :absolute_path ] if attrs.key?( :absolute_path )
        @present = attrs[ :present ] if attrs.key?( :present )
        @type = attrs[ :type ] if attrs.key?( :type )
        @size_listed = attrs[ :size_listed ] if attrs.key?( :size_listed )
        @size_actual = attrs[ :size_actual ] if attrs.key?( :size_actual )
        @hash_expected = attrs[ :hash_expected ] if attrs.key?( :hash_expected )
        @hash_digest = attrs[ :hash_digest ] if attrs.key?( :hash_digest )
        @hash_status = attrs[ :hash_status ] if attrs.key?( :hash_status )
      end

      def add_packing_list( pkl )
        @packing_lists << pkl unless @packing_lists.include?( pkl )
      end

      def add_reel_reference( reel_asset )
        @reel_references << reel_asset unless @reel_references.include?( reel_asset )
      end

      def to_h
        {
          :id => @id,
          :assetmap_id => @assetmap ? @assetmap.id : nil,
          :assetmap_path => @assetmap_path,
          :packing_list_path => @packing_list_path,
          :absolute_path => @absolute_path,
          :present => @present,
          :type => @type,
          :size_listed => @size_listed,
          :size_actual => @size_actual,
          :hash_expected => @hash_expected,
          :hash_digest => @hash_digest,
          :hash_status => @hash_status,
          :packing_list_ids => @packing_lists.map { |pkl| pkl.id },
          :reel_references => @reel_references.map do |ref|
            {
              :composition_id => ref.reel.composition.id,
              :reel_number => ref.reel.number,
              :kind => ref.kind
            }
          end,
          :checks => checks_to_h
        }
      end
    end


    # Workaround Nokogiri::XML::Document#collect_namespaces peculiarity
    # (see https://github.com/sparklemotion/nokogiri/issues/885 for details)
    #
    # collect_all_namespaces_href_keys will return
    #
    #   {
    #     "http://www.w3.org/XML/1998/namespace"              =>  ["xml"],
    #     "http://www.smpte-ra.org/schemas/429-7/2006/CPL"    =>  [nil],
    #     "http://isdcf.com/schemas/draft/2011/cpl-metadata"  =>  ["meta"],
    #     "http://www.w3.org/2000/09/xmldsig#"                =>  [nil]
    #   }
    #
    # where nil implies xmlns.
    # This is an example where multiple default namespace definitions exist
    # and are used in different document fragments.
    #
    # collect_all_namespaces_prefix_keys will return
    #
    #   {
    #     "xml"   =>  ["http://www.w3.org/XML/1998/namespace"],
    #     "nil"   =>  ["http://www.smpte-ra.org/schemas/429-7/2006/CPL", "http://www.w3.org/2000/09/xmldsig#"],
    #     "meta"  =>  ["http://isdcf.com/schemas/draft/2011/cpl-metadata"]
    #   }
    #
  end
end
