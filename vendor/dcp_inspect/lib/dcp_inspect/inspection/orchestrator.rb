# frozen_string_literal: true

module DcpInspect
  module Inspection
    class Runtime
      module Orchestrator
      def filesystem_walker
        @filesystem_walker ||= DcpInspect::FilesystemWalker.new
      end


      def report_filesystem_warnings
        filesystem_walker.warnings.each do |warning|
          @logger.info "Filesystem traversal warning: #{ warning }"
        end
      end


      def find_assetmap_candidates( package_dir )
        am_candidates = filesystem_walker.assetmap_candidates( package_dir )
        report_filesystem_warnings
        am_candidates.each { |candidate| @logger.debug candidate }
        am_candidates
      rescue DcpInspect::FilesystemWalker::TraversalError => error
        @logger.info error.message
        raise DcpInspect::Inspection::Error.new(error.message, FILE_ACCESS_ERROR)
      end


      def find_regular_files( root )
        files = filesystem_walker.files( root )
        report_filesystem_warnings
        files
      rescue DcpInspect::FilesystemWalker::TraversalError => error
        @logger.info error.message
        raise DcpInspect::Inspection::Error.new(error.message, FILE_ACCESS_ERROR)
      end


      def dcp_inspect( options, arg )
        errors = Array.new
        hints = Array.new
        siginfo = Array.new
        info = Array.new
        composition_summaries = Array.new
        inspection_run = InspectionRun.new( arg )
        if ( dashboard = tfs_dashboard )
          dashboard.track_findings( :errors => errors, :hints => hints, :siginfo => siginfo )
          dashboard.attach_run( inspection_run, arg )
        end

        @package_dir = arg
        #
        # Find files called what Assetmap(s) would be called.
        # Don't assume they're actually Assetmaps before checking.
        #
        # Searching at
        @logger.info "Searching Assetmaps at #{ @package_dir }"

        am_candidates = find_assetmap_candidates( @package_dir )
        am_candidates_rejects = Array.new
        if am_candidates.empty?
          info << 'No Assetmap candidates found'
        else
          @logger.debug "Found #{ amount( 'Assetmap candidate', am_candidates ) } ✅:"
        end

        # Check for Assetmap content
        unless am_candidates.empty?
          am_candidates_tmp = am_candidates.dup

          am_candidates.each do |am_candidate|
            am_file = package am_candidate
            error_status = false
            xml, errors, error_status = get_xml_of_type( 'AssetMap', am_file, errors, error_status )
            if xml

              # Schema validation
              am_id = get_asset_uuid( am_file )
              assetmap_model = inspection_run.assetmap( am_id || am_file, :path => am_file, :absolute_path => am_file, :present => true )
              if options.schema_validate
                begin
                  valid, errors, error_status = schema_validation( errors, true, xml, am_file, am_id, 'AM' )
                  assetmap_model.schema_status = valid ? 'OK' : 'Errors'
                  inspection_run.add_check( assetmap_model, :schema, valid ? :ok : :error, "AM candidate #{ am_id.nil? ? am_id.inspect : am_id }" )
                  @logger.debug "AM candidate #{ am_id.nil? ? am_id.inspect : am_id }: Schema check: #{ valid ? 'OK ✅' : "Errors ❌ (See #{ error_output })" }: #{ am_file }"
                rescue Exception => e
                  errors << "AM #{ am_id.nil? ? am_id.inspect : am_id }: Exception in Schema check ❌: #{ e.message }"
                  error_status = true
                  assetmap_model.schema_status = 'Errors'
                  inspection_run.add_check( assetmap_model, :schema, :error, errors.last )
                  @logger.debug errors.last
                end
              end

            else
              @logger.debug "AM candidate #{ am_file.inspect }: Not XML"
              am_candidates_rejects << am_candidate
              am_candidates_tmp.delete( am_candidate )
            end
          end

          if am_candidates_rejects.any?
            am_candidates_rejects.each do |am_candidates_reject|
              @logger.debug "Not AM: #{ am_candidates_reject }"
            end
          end
          am_candidates = am_candidates_tmp.dup
        end
        am_files = am_candidates
        @logger.debug ''

        # Process all Assetmaps
        @logger.debug "Found #{ amount( 'Assetmap', am_files ) }"
        dict = Array.new # list of dictionaries/hashes
        pkls = Array.new
        pkls_missing = Array.new
        ams = Array.new
        am_files.each_with_index do |am_file, index|
          am_errors = false
          dict << Hash.new
          pkls << Array.new
          pkls_missing << Array.new
          am_base = File.dirname am_file
          # FIXME doing XML again after candidate checking did that already
          xml = xml?( package am_file )
          if xml.root.namespace
            am_ns = xml.root.namespace.href
          end

          # FIXME
          xml.remove_namespaces!
          # FIXME and get_asset_uuid() is doing XML yet again
          am_id = get_asset_uuid( package am_file )

          if am_id
            ams << am_id
            assetmap_model = inspection_run.assetmap( am_id, :path => am_file, :absolute_path => package( am_file ), :base => am_base, :namespace => am_ns, :present => true )

            case am_ns
            when MStr::Smpte_am
              unless File.basename( am_file ) == 'ASSETMAP.xml'
                errors << "AM #{ am_id }: #{ am_file.inspect }: SMPTE Assetmap file cannot be named #{ File.basename( am_file ).inspect }. Must be named \"ASSETMAP.xml\""
                am_errors = true
              end
            when MStr::Interop_am
              unless File.basename( am_file ) == 'ASSETMAP'
                errors << "AM #{ am_id }: #{ am_file.inspect }: Interop Assetmap file cannot be named #{ File.basename( am_file ).inspect }. Must be named \"ASSETMAP\""
                am_errors = true
              end
            else
              errors << "AM #{ am_id }: #{ am_file.inspect }: Alleged AM file has invalid namespace #{ am_ns.inspect }"
              am_errors = true
            end

            #
            # Good to go minus possible namespace issue
            #
            # collect all asset nodes
            assets = xml.xpath( '//Asset' )
            MetadataChecks.duplicate_ids(assets.xpath('Id')).each do |id|
              errors << "AM #{am_id}: Duplicate Asset Id #{id} ❌"
              am_errors = true
            end
            assetmap_model.asset_count = assets.size

            @logger.debug "AM #{ am_id }: #{ am_file }"
            @logger.debug "AM #{ am_id } lists #{ amount( 'asset', assets.size ) }:"

            # Store asset info in a dictionary (uuid => path, relative to package root)
            # look for PackingList(s)
            assets.each do |asset|

              listed_id = asset.xpath( 'Id' ).text.split( ':' ).last
              # FIXME ChunkList.size == 1 is an assumption and wrong at that. Could be > 1
              # using AM listed path for listing message, not package path, because this is what we're looking at right now:
              path = asset.xpath( 'ChunkList/Chunk/Path' ).text.split( /file:\/+/ ).last

              # Check for UUID specs. Defer RFC-4122 compliance check to a later stage where we know asset kind
              # DCSubtitle does not require RFC-4122 UUID
              if listed_id.downcase !~ MStr::Uuid_re
                errors << "AM #{ am_id }: Listed in Assetmap: Not a UUID: #{ path }: #{ listed_id }"
                am_errors = true
              end

              # Path element present? See e.g. mc t28 ASSETMAP.xml
              if path.nil?
                errors << "AM #{ am_id }: No path for asset: #{ listed_id }"
                am_errors = true
              else

                # Assetmap dictionary
                dict[ index ][ listed_id ] = Pathname( File.join( am_base, path ) ).cleanpath.to_s
                asset_file = package dict[ index ][ listed_id ]
                inspection_run.asset(
                  listed_id,
                  :assetmap_id => am_id,
                  :assetmap_path => dict[ index ][ listed_id ],
                  :absolute_path => asset_file,
                  :present => File.exist?( asset_file )
                )
                @logger.debug "#{ listed_id }: #{ dict[ index ][ listed_id ] }#{ File.exist?( package dict[ index ][ listed_id ] ) ? '' : ' (file missing) ❌' }"

                # Check listed_id vs actual asset_id
                if File.exist?( asset_file )
                  asset_id = get_asset_uuid( asset_file )
                  if asset_id
                    unless asset_id.downcase =~ MStr::Uuid_re
                      errors << "AM #{ am_id }: Asset UUID: Not a UUID ❌: #{ asset_file }: #{ asset_id }"
                      am_errors = true
                    end
                    if listed_id.downcase != asset_id.downcase
                      errors << "AM #{ am_id }: UUID mismatch ❌: #{ asset_file }: Listed: #{ listed_id } Asset: #{ asset_id }"
                      am_errors = true
                    else
                      if listed_id != asset_id
                        hints << "AM #{ am_id }: UUID case mismatch: #{ asset_file }: Listed: #{ listed_id } Asset: #{ asset_id }"
                      end
                    end
                  end
                else
                  errors << "AM #{ am_id }: Listed asset file missing ❌: #{ listed_id }: #{ path }: #{ asset_file }"
                  am_errors = true
                end

                # Check for Chunklist:Chunk:Length element and compare to actual asset size.
                # In the case of a mismatch this results in a hint as Length is optional
                # and no crucial processing can depend on it. Field behaviour undefined ttbomk.
                if File.exist?( asset_file )
                  length_el = asset.xpath( 'ChunkList/Chunk/Length' )
                  if ! length_el.empty?
                    begin
                      listed_asset_length = asset.xpath( 'ChunkList/Chunk/Length' ).text.to_i
                      asset_size = File.size asset_file
                      unless listed_asset_length == asset_size
                      errors << "AM #{ am_id }: Mismatch in optional Length element ❌: Asset: #{ listed_id }: Listed length: #{ listed_asset_length } (#{ listed_asset_length.to_k }) #{ asset_file.inspect } on medium: #{ asset_size } (#{ asset_size.to_k })"
                        am_errors = true
                      end
                    rescue Exception => e
                      errors << "AM #{ am_id }: Asset #{ listed_id }: File #{ asset_file.inspect }: Length check fail ❌: #{ e.message }"
                      am_errors = true
                    end
                  end
                end

                # Check asset filename for whitespace (keep this as distinct check)
                if path.scan( /\s+/ ).size != 0
                  case am_ns
                  when MStr::Smpte_am
                    errors << "AM SMPTE #{ am_id }: Asset #{ listed_id }: Filename #{ path.inspect } contains whitespace"
                    am_errors = true
                  when MStr::Interop_am
                    hints << "AM Interop #{ am_id }: Asset #{ listed_id }: Filename #{ path.inspect } contains whitespace. Avoid whitespace in filenames"
                  end
                end
                # Check asset filename for codepoints outside of [0-9A-Za-z_-.]
                char_outsiders = /[^-._\/0-9A-Za-z]/ # path separator is valid. TODO number of segments etc.
                match_char_outsiders = path.split('').map { |m| m =~ char_outsiders }
                if match_char_outsiders.include? 0
                  path_hinted = ''
                  path.split('').each_with_index do |m, i|
                    if match_char_outsiders[i].nil?
                      path_hinted += m
                    else
                      path_hinted += m.invert
                    end
                  end
                  case am_ns
                  when MStr::Smpte_am
                    errors << "AM SMPTE #{ am_id }: Asset #{ listed_id }: Filename \"#{ path_hinted }\" contains characters outside of (-._0-9A-Za-z)"
                    am_errors = true
                  when MStr::Interop_am
                    hints << "AM Interop #{ am_id }: Asset #{ listed_id }: Filename \"#{ path_hinted }\" contains characters outside of (-._0-9A-Za-z). Avoid these characters in filenames"
                  end
                end
                # Check asset filename for length
                if am_ns == MStr::Smpte_am and path.codepoints.size > 100
                  errors << "AM SMPTE #{ am_id }: Asset #{ listed_id }: Filename #{ path.inspect } longer than 100 characters (#{ path.codepoints.size })"
                  am_errors = true
                end
                if am_ns == MStr::Interop_am and path.codepoints.size > 255
                  errors << "AM Interop #{ am_id }: Asset #{ listed_id }: Filename #{ path.inspect } longer than 255 characters (#{ path.codepoints.size })"
                  am_errors = true
                end

              end # path.nil?

              # PackingList?
              packing_list = asset.at_xpath( 'PackingList' )
              is_packing_list = false
              if packing_list
                case am_ns
                when MStr::Interop_am
                  is_packing_list = true
                when MStr::Smpte_am
                  # xs:boolean permits true/false and 1/0, with whitespace
                  # collapsed. Presence alone does not identify a PKL.
                  case packing_list.text.strip
                  when 'true', '1'
                    is_packing_list = true
                  when 'false', '0'
                    is_packing_list = false
                  else
                    errors << "AM #{ am_id }: Asset #{ listed_id }: Invalid SMPTE PackingList boolean #{ packing_list.text.inspect }; expected true, false, 1 or 0"
                    am_errors = true
                  end
                end
              end
              if is_packing_list
                if path
                  inspection_run.packing_list(
                    listed_id,
                    :assetmap_id => am_id,
                    :path => dict[ index ][ listed_id ],
                    :absolute_path => package( dict[ index ][ listed_id ] ),
                    :present => File.exist?( package( dict[ index ][ listed_id ] ) )
                  )
                  pkls[ index ] << listed_id
                else
                  errors << "AM #{ am_id }: Found alleged PackingList asset #{ listed_id } but Path element is empty. Not adding to dictionary ❌"
                  am_errors = true
                end
              end

              # Check if possible uuid component in the asset filename matches the actual asset uuid
              if dict[ index ][ listed_id ]
                file_basename = File.basename( dict[ index ][ listed_id ] )
                if file_basename =~ MStr::Uuid_particle_re
                  unless file_basename.match( MStr::Uuid_particle_re )[ 0 ] == listed_id
                    hints << "Asset UUID and filename UUID component mismatch: #{ listed_id } -> #{ file_basename }"
                  end
                end
              end

            end # assets.each

            # Check for files outside of AM's scope
            # FIXME Consider unmapped files which are valid DC XML (e.g. 'ASSETMAP~'')
            # FIXME and may cause trouble when agnostic Dolbys pick them up
            am_base_absolute = File.expand_path( am_base, @package_dir )

            dcp_files = dict[ index ].values
            dcp_files << am_file
            # In the words of the immortal Noel Gallagher:
            # "Exactly noone gives a hoot about VOLINDEX."
            [ 'VOLINDEX', 'VOLINDEX.xml' ].each do |v|
              if File.exist?( File.join( am_base_absolute, v ) )
                dcp_files << File.join( am_base_absolute, v )
              end
            end
            dcp_files = dcp_files.map { |path| File.expand_path( path, @package_dir ) }
            dcp_files.sort_by!( &:downcase )

            files_in_am_base = find_regular_files( am_base_absolute )

            outsider_files = files_in_am_base - dcp_files
            outsider_files = outsider_files.map { |path| path.split( am_base_absolute + '/' )[1] }

            if outsider_files.any?
              hints << "AM #{ am_id }: Found #{ amount( 'file', outsider_files ) } outside of AM (#{ File.basename am_base }): #{ outsider_files.map { |path| path.inspect }.join( ', ' ) }"
              @logger.debug hints.last
            end


          else
            ams << nil
            errors << "Assetmap '#{ am_file }' has no Id"
            am_errors = true
          end

          # List this Assetmap's PKLs
          @logger.debug "AM #{ am_id } lists #{ amount( 'PKL', pkls[ index ] ) }:"
          pkls[ index ].map { |pkl_id|
            pkl_file = package dict[ index ][ pkl_id ]
            inspection_run.packing_list(
              pkl_id,
              :assetmap_id => am_id,
              :path => dict[ index ][ pkl_id ],
              :absolute_path => pkl_file,
              :present => File.exist?( pkl_file )
            )
            if File.exist?( pkl_file )
              @logger.debug "PKL file present ✅: #{ pkl_id }: #{ pkl_file }"
            else
              pkls_missing[ index ] << pkl_id
              errors << "AM #{ am_id }: PKL file missing ❌: #{ pkl_id }: #{ pkl_file }"
              am_errors = true
              @logger.debug errors.last
            end
          }
          pkls_missing[ index ].map { |pkl_id| pkls[ index ].delete pkl_id }

          if am_errors == true
            @logger.debug "There were errors ❌. See AM #{ am_id } errors #{ error_output }"
          end

          @logger.debug nil

        end # am_files.each

        #
        # Experimental option --as-asset-store
        #
        # This will merge all collected dictionaries and flatten pkls accordingly.
        # Naive merge, though, for now. No asset normalization either.
        #
        # Also composition completeness info won't hint at the "use"
        # of external assets. Use if you know what you are doing.
        #
        # Can be used to simulate ingest and completeness checks for VF compositions.
        #
        if options.as_asset_store
          dict_tmp = Array.new << Hash.new
          dict.map { |d| dict_tmp.first.merge!( d ) { |k, v1, v2| v1 || v2 } }
          dict = dict_tmp
          pkls = Array.new << pkls.flatten
        end

        # List all found PKLs
        @logger.debug "Found #{ amount( 'Package', pkls.flatten ) }"
        pkls.each_with_index do |am_pkls, index|
          am_pkls.each do |pkl_id|
            if dict[ index ][ pkl_id ]
              pkl_file = package dict[ index ][ pkl_id ]
              if File.exist?( pkl_file )
                @logger.debug "PKL file present ✅: #{ [ pkl_id, pkl_file ].join( ': ' ) }"
              else
                @logger.debug "PKL file missing ❌: #{ [ pkl_id, pkl_file ].join( ': ' ) }"
              end
            end
          end
        end
        @logger.debug '' unless pkls.empty?

        # Process all PackingLists
        cpls = Array.new
        cpl_contexts = Array.new
        cpls_missing = Array.new
        store_hashes = Hash.new { |hash, id| hash[id] = [] }
        packages_size_listed = 0
        packages_size_actual = 0

        pkls.each_with_index do |am_pkls, index|
          cpls << Array.new
          cpl_contexts << Array.new
          cpls_missing << Array.new
          am_pkls.each do |pkl_id|
            pkl_errors = false
            pkl_file = package dict[ index ][ pkl_id ]
            pkl_model = inspection_run.packing_list(
              pkl_id,
              :assetmap_id => ams[ index ],
              :path => dict[ index ][ pkl_id ],
              :absolute_path => pkl_file,
              :present => File.exist?( pkl_file )
            )
            xml, errors, pkl_errors = get_xml_of_type( 'PackingList', pkl_file, errors, pkl_errors )
            if xml

              @logger.debug "PKL #{ pkl_id }: #{ pkl_file }"
              pkl_namespace = xml.root.namespace&.href

              if options.schema_validate
                begin
                  valid, errors, pkl_errors = schema_validation( errors, pkl_errors, xml, pkl_file, pkl_id, 'PKL' )
                  pkl_model.schema_status = valid ? 'OK' : 'Errors'
                  inspection_run.add_check( pkl_model, :schema, valid ? :ok : :error, "PKL #{ pkl_id }" )
                  @logger.debug "PKL #{ pkl_id }: Schema check: #{ valid ? 'OK ✅' : "Errors ❌ (See #{ error_output })" }"
                rescue Exception => e
                  errors << "PKL #{ pkl_id }: Exception in Schema check ❌: #{ e.message }"
                  pkl_errors = true
                  pkl_model.schema_status = 'Errors'
                  inspection_run.add_check( pkl_model, :schema, :error, errors.last )
                  @logger.debug errors.last
                end
              end

              if @c14n_available
                signature_result = check_signature( xml )
                if signature_result.check_status == :ok
                  @signed_pkls_verified_count += 1
                end
                unless signature_result.signature_node.empty?
                  errors, pkl_errors = signature_verification_errors( errors, pkl_errors, signature_result, pkl_id, pkl_file, 'PKL' )
                  hints = signature_verification_hints( hints, signature_result, pkl_id, pkl_file, 'PKL' )
                  siginfo = signature_verification_siginfo( siginfo, signature_result, pkl_id, pkl_file, 'PKL' )
                end
                pkl_model.signature_status = signature_result.messages.last
                inspection_run.add_check( pkl_model, :signature, signature_result.check_status, signature_result.messages.last, signature_result.verification_details )
                @logger.debug "PKL #{ pkl_id }: #{ signature_result.messages.last }"
                if signature_result and ! signature_result.signature_node.empty?
                  @signed_pkls_count += 1
                  sig_info = signer_info( xml, signature_result )
                  short_report = build_signer_issuer_short_report( xml, signature_result, sig_info, 'PKL' )
                  unless short_report.empty?
                    @logger.debug short_report[ 0 ]
                    @logger.debug short_report[ 1 ]
                  end
                end
              else
                signature_result = nil
              end

              # FIXME
              pkl_unsigned = xml.xpath('//*[local-name()="Signature" and namespace-uri()="http://www.w3.org/2000/09/xmldsig#"]').empty?
              pkl_encrypted_asset_ids = []
              xml.remove_namespaces!

              pkl_annotation_text = xml.xpath( '/PackingList/AnnotationText' ).text
              if pkl_annotation_text.empty?
                pkl_model.annotation = '[Empty]'
                @logger.debug "PKL #{ pkl_id }: AnnotationText: [Empty]"
              else
                pkl_model.annotation = pkl_annotation_text
                @logger.debug "PKL #{ pkl_id }: AnnotationText: #{ pkl_annotation_text }"
              end

              package_size_listed = 0
              package_size_actual = 0
              pkl_cpls = Array.new

              pkl_assets = xml.xpath( '//Asset' )
              MetadataChecks.duplicate_ids(pkl_assets.xpath('Id')).each do |id|
                errors << "PKL #{pkl_id}: Duplicate Asset Id #{id} ❌"
                pkl_errors = true
              end
              pkl_hashes = options.as_asset_store ? store_hashes : Hash.new { |hash, id| hash[id] = [] }
              pkl_assets.each do |asset|
                id = asset.at_xpath('Id')&.text.to_s.split(':').last
                digest = asset.at_xpath('Hash')&.text.to_s.gsub(/\s+/, '')
                pkl_hashes[id] << { pkl_id: pkl_id, hash: digest } unless id.to_s.empty? || digest.empty?
              end
              pkl_model.asset_count = pkl_assets.size
              @logger.debug "PKL #{ pkl_id } lists #{ amount( 'asset', pkl_assets.size ) }"
              pkl_asset_ids = pkl_assets.map { |asset| asset.xpath( 'Id' ).text.split( ':' ).last }.reject { |id| id.empty? }
              pkl_dict = options.as_asset_store ? dict[ index ] : dict[ index ].select { |id, _| pkl_asset_ids.include?( id ) }

              early_cpl_attempts = {}
              hash_priorities = {}
              hash_jobs = []
              pkl_assets.each do |asset|
                id = asset.xpath( 'Id' ).text.split( ':' ).last
                next if id.empty?

                type = asset.xpath( 'Type' ).text
                asset_path = dict[ index ][ id ]
                asset_file_for_model = asset_path ? package( asset_path ) : nil
                inspection_run.asset(
                  id,
                  :packing_list_id => pkl_id,
                  :packing_list_path => asset_path,
                  :absolute_path => asset_file_for_model,
                  :present => asset_file_for_model ? File.exist?( asset_file_for_model ) : false,
                  :type => type.empty? ? '[Type not specified in PKL]' : type,
                  :size_listed => asset.xpath( 'Size' ).text.to_i
                )

                next unless type =~ /text\/xml/
                next unless asset_file_for_model && File.exist?( asset_file_for_model )

                early_cpl_attempts[ id ] = true
                cpl_xml, errors, pkl_errors = get_xml_of_type( 'CompositionPlaylist', asset_file_for_model, errors, pkl_errors )
                if cpl_xml
                  pkl_cpls << id unless pkl_cpls.include?( id )
                  cpls[ index ] << id unless cpls[ index ].include?( id )
                  register_cpl_hash_priorities( hash_priorities, cpl_xml, pkl_cpls.index( id ) || 0 )
                  inspection_run.composition(
                    id,
                    :packing_list_id => pkl_id,
                    :path => asset_path,
                    :absolute_path => asset_file_for_model,
                    :present => true
                  )
                  preview_cpl_model( inspection_run, cpl_xml, dict[ index ], pkl_id )
                end
              end

              pkl_assets.each_with_index do |asset, pkl_asset_order|
                id = asset.xpath( 'Id' ).text.split( ':' ).last
                if id.empty?
                  errors << "PKL #{ pkl_id }: Asset Id missing ❌"
                  pkl_errors = true
                end
                type = asset.xpath( 'Type' ).text
                if type.empty?
                  errors << "PKL #{ pkl_id }: Asset type not specified: #{ id }"
                  pkl_errors = true
                end
                asset_path = dict[ index ][ id ]
                asset_file_for_model = asset_path ? package( asset_path ) : nil
                asset_model = id.empty? ? nil : inspection_run.asset(
                  id,
                  :packing_list_id => pkl_id,
                  :packing_list_path => asset_path,
                  :absolute_path => asset_file_for_model,
                  :present => asset_file_for_model ? File.exist?( asset_file_for_model ) : false,
                  :type => type.empty? ? '[Type not specified in PKL]' : type,
                  :size_listed => asset.xpath( 'Size' ).text.to_i
                )
                # List all assets listed in PKL and report AM mapping status
                @logger.debug "#{ id }: #{ type.empty? ? '[Type not specified in PKL]' : type }: #{ dict[ index ][ id ] ? File.exist?( package dict[ index ][ id ] ) ? dict[ index ][ id ] : dict[ index ][ id ] + ' (missing) ❌' : 'Asset UUID not in assetmap dictionary' }"

                if dict[ index ].keys.include?( id )
                  asset_file = package dict[ index ][ id ]
                  size_listed = asset.xpath( 'Size' ).text.to_i

                  if File.exist?( asset_file )
                    if pkl_namespace == MStr::Smpte_pkl && inspect_mxf(asset_file)&.fetch('EncryptedEssence', nil) == 'Yes'
                      pkl_encrypted_asset_ids << id
                    end
                    inspect_pkl_asset_type(asset_file, type, pkl_namespace).each do |message|
                      errors << "PKL #{pkl_id}: Asset #{id}: #{message} ❌"
                      pkl_errors = true
                      inspection_run.add_check(asset_model, :type, :error, errors.last) if asset_model
                    end
                    size_asset = File.size( asset_file )
                    asset_model.size_actual = size_asset if asset_model
                    #
                    # Plug in checks here. we might be skipping validation hence the tag test
                    #
                    # Check listed and actual asset size
                    if size_listed
                      if size_listed != size_asset
                        errors << "PKL #{ pkl_id }: Size mismatch ❌: #{ id }: PKL: #{ size_listed } (#{ size_listed.to_k }) Asset: #{ size_asset } (#{ size_asset.to_k })"
                        pkl_errors = true
                      end
                      package_size_listed += size_listed
                      package_size_actual += size_asset
                    else
                      errors << "PKL #{ pkl_id }: Size tag missing or bad content ❌: #{ id }: #{ asset_file }: #{ type.empty? ? '[Type not specified in PKL]' : type }"
                      pkl_errors = true
                    end

                    # Check listed and actual digests
                    if ! asset.xpath( 'Hash' ).empty?
                      if ( hash_listed = asset.xpath( 'Hash' ).text )
                        asset_model.hash_expected = hash_listed if asset_model
                        if hash_listed.empty?
                          errors << "PKL #{ pkl_id }: Hash element is empty: See PKL file #{ pkl_file } line #{ asset.xpath( 'Hash' ).first.line }"
                          errors << "PKL #{ pkl_id }: Asset has no associated hash value in metadata: #{ id }: #{ asset_file }: #{ type.empty? ? '[Type not specified in PKL]' : type }"
                          if asset_model
                            asset_model.hash_status = 'empty'
                            inspection_run.add_check( asset_model, :hash, :error, errors.last )
                          end
                          @logger.debug "#{ id }: Checking hash value: Asset has no associated hash value in metadata: See errors #{ error_output }"
                          pkl_errors = true
                        else
                          if options.check_hashes
                            if options.skip_png_hashes && File.binread(asset_file, 8) == "\x89PNG\r\n\x1a\n".b
                              @check_hashes_png_hits += 1
                              hints << "PKL #{ pkl_id }: Hash check skipped (--np): PNG asset #{ id }, Path #{ asset_file }, Expected hash: #{ hash_listed }"
                              if asset_model
                                asset_model.hash_status = 'skipped PNG (--np)'
                                inspection_run.add_check( asset_model, :hash, :skipped, hints.last )
                              end
                              @logger.debug hints.last
                            elsif options.check_hashes_limit == :no_limit or bytes_from_nice_bytes( options.check_hashes_limit ) > size_asset
                              @check_hashes_hits += 1
                              hash_jobs << {
                                :priority => hash_priority_for_pkl_asset( id, type, pkl_asset_order, hash_priorities ),
                                :id => id,
                                :pkl_id => pkl_id,
                                :asset_file => asset_file,
                                :asset_model => asset_model,
                                :hash_listed => hash_listed
                              }
                            else
                              @check_hashes_limit_hits += 1
                              hints << "PKL #{ pkl_id }: Hash check skipped: File size #{ size_asset.to_k } > #{ bytes_from_nice_bytes( options.check_hashes_limit ).to_k } limit: Asset #{ id }, Path #{ asset_file }, Expected hash: #{ hash_listed }"
                              if asset_model
                                asset_model.hash_status = 'skipped by size'
                                inspection_run.add_check( asset_model, :hash, :skipped, hints.last )
                              end
                              @logger.debug hints.last
                            end
                          else
                            if asset_model
                              asset_model.hash_status = 'skipped'
                              inspection_run.add_check( asset_model, :hash, :skipped, "Hash check skipped: #{ asset_file }" )
                            end
                            @logger.debug "#{ id }: Hash check skipped: Path: #{ asset_file }, Expected hash: #{ hash_listed }"
                          end
                        end
                      end
                    else
                      errors << "PKL #{ pkl_id }: Hash element missing or bad content ❌: #{ asset_file }: #{ type.empty? ? '[Type not specified in PKL]' : type }: #{ id }"
                      if asset_model
                        asset_model.hash_status = 'missing'
                        inspection_run.add_check( asset_model, :hash, :error, errors.last )
                      end
                      pkl_errors = true
                    end

                    # Pick CPLs
                    if type =~ /text\/xml/ && ! early_cpl_attempts[ id ]
                      xml, errors, errors_status = get_xml_of_type( 'CompositionPlaylist', asset_file, errors, errors_status = false )
                      if xml
                        pkl_cpls << id unless pkl_cpls.include?( id )
                        cpls[ index ] << id unless cpls[ index ].include?( id )
                        register_cpl_hash_priorities( hash_priorities, xml, pkl_cpls.index( id ) || 0 )
                        inspection_run.composition(
                          id,
                          :packing_list_id => pkl_id,
                          :path => dict[ index ][ id ],
                          :absolute_path => asset_file,
                          :present => true
                        )
                        preview_cpl_model( inspection_run, xml, dict[ index ], pkl_id )
                      end
                    end
                    #
                    #
                  else
                    # asset_file does not exist
                    errors << "PKL #{ pkl_id }: Asset file missing ❌: #{ id }: #{ asset_file }"
                    if asset_model
                      asset_model.hash_status = 'missing file'
                      inspection_run.add_check( asset_model, :presence, :error, errors.last )
                    end
                    pkl_errors = true
                    package_size_listed += size_listed
                    package_size_actual += 0
                  end

                else
                  # For some reason the listed id in PackingList is not in assetmap dictionary
                  # Possibly been tampered with
                  errors << "Asset UUID not in assetmap dictionary: PKL #{ pkl_id }: #{ id } (#{ type })"
                  if asset_model
                    asset_model.hash_status = 'not in AssetMap'
                    inspection_run.add_check( asset_model, :presence, :error, errors.last )
                  end
                  pkl_errors = true
                end

              end
              hash_jobs.sort_by { |job| job[ :priority ] }.each do |job|
                asset_model = job[ :asset_model ]
                etabar_title = "#{ job[ :id ] }: Checking hash value:"
                if asset_model
                  asset_model.hash_status = 'checking'
                  inspection_run.event( :asset, asset_model, :hash_status => 'checking' )
                end
                hash_check, eta = digest_with_etabar( digest_algorithm = 'sha1', title = etabar_title, file = job[ :asset_file ], width = 20, looks_like = '[= ]', opts = options, logger = @logger )
                hash_check_b64 = Base64.encode64( hash_check ).chomp
                asset_model.hash_digest = hash_check_b64 if asset_model
                if job[ :hash_listed ] != hash_check_b64
                  eta.preserve_terminal_title_with_message( "Mismatch ❌ (#{ time_string( eta.elapsed ) })" )
                  errors << "PKL #{ job[ :pkl_id ] }: Hash mismatch ❌: #{ job[ :id ] }: PKL: #{ job[ :hash_listed ] } Asset: #{ hash_check_b64 }"
                  if asset_model
                    asset_model.hash_status = 'mismatch'
                    inspection_run.add_check( asset_model, :hash, :error, errors.last )
                  end
                  pkl_errors = true
                else
                  eta.preserve_terminal_title_with_message( "OK ✅ (#{ time_string( eta.elapsed ) })" )
                  info << "Hash value: OK: #{ job[ :id ] }: #{ job[ :asset_file ] }: #{ hash_check_b64 }"
                  if asset_model
                    asset_model.hash_status = 'OK'
                    inspection_run.add_check( asset_model, :hash, :ok, info.last )
                  end
                end
              end
              if pkl_namespace == MStr::Smpte_pkl && pkl_unsigned && pkl_encrypted_asset_ids.any?
                message = "PKL #{pkl_id}: Unsigned SMPTE PKL lists observed encrypted essence. DCI DCSS 5.5.2.3 requires signing such Packing Lists for transport integrity. PKL signing does not establish CPL ContentAuthenticator compatibility or determine a KDM formulation."
                hints << message
                @logger.debug message
                inspection_run.add_check(pkl_model, :unsigned_encrypted, :hint, message,
                  { encrypted_asset_ids: pkl_encrypted_asset_ids.uniq })
              end
              # Include declarations for assets absent from the AssetMap too.
              # Invalid declarations must not become plausible zero-byte totals.
              declared_sizes = pkl_assets.map { |asset| Timing.units(asset.xpath('Size').text) }
              package_size_listed = declared_sizes.sum if declared_sizes.all?
              pkl_model.package_size_listed = declared_sizes.all? ? package_size_listed : nil
              pkl_model.package_size_actual = package_size_actual
              @logger.debug "PKL #{ pkl_id }: Package size: #{ package_size_actual == package_size_listed ? package_size_actual.to_k : package_size_actual.to_k + ' (Listed: ' + package_size_listed.to_k + ')' }"
              # List this PKLs CPLs
              @logger.debug "PKL #{ pkl_id } lists #{ amount( 'composition', pkl_cpls ) }"
              pkl_cpls.map { |cpl_id|
                cpl_file = package dict[ index ][ cpl_id ]
                inspection_run.composition(
                  cpl_id,
                  :packing_list_id => pkl_id,
                  :path => dict[ index ][ cpl_id ],
                  :absolute_path => cpl_file,
                  :present => File.exist?( cpl_file )
                )
                if File.exist?( cpl_file )
                  @logger.debug "CPL file present ✅: #{ cpl_id }: #{ cpl_file }"
                  unless options.as_asset_store && cpl_contexts[ index ].any? { |context| context[ :cpl_id ] == cpl_id }
                    cpl_contexts[ index ] << {
                      :cpl_id => cpl_id,
                      :pkl_id => pkl_id,
                      :pkl_hashes => pkl_hashes,
                      :pkl_asset_ids => pkl_asset_ids.dup,
                      :resource_dict => dict[index],
                      :dict => pkl_dict
                    }
                  end
                else
                  cpls_missing[ index ] << cpl_id
                  errors << "CPL #{ cpl_id }: CPL file missing ❌: #{ cpl_file }"
                  @logger.debug errors.last
                  pkl_errors = true
                end
              }
              cpls_missing[ index ].map { |cpl_id| cpls[ index ].delete cpl_id }
            else
              errors << "Not a PackingList: #{ pkl_file }"
              @logger.debug errors.last
              pkl_errors = true
            end
            if package_size_listed
              packages_size_listed += package_size_listed
              packages_size_actual += package_size_actual
              package_size_listed, package_size_actual = nil, nil
            end

            if pkl_errors == true
              @logger.debug "There were errors ❌. See PKL #{ pkl_id } errors #{ error_output }"
            end

            @logger.debug ''
          end # am_pkls.each
        end # pkls.each

        # List all found CPLs
        if cpls.flatten.size > 0
          @logger.debug "Found #{ amount( 'Composition', cpls.flatten ) }"
          dict.each_with_index do |dictionary, index|
            cpls[ index ].each do |cpl_id|
              cpl_file = package dictionary[ cpl_id ]
              if File.exist? cpl_file
                @logger.debug "CPL file present ✅: #{ cpl_id }: #{ cpl_file }"
              else
                errors << "CPL #{ cpl_id }: CPL file missing ❌: #{ cpl_file }"
                @logger.debug errors.last
              end
            end
          end
        else
          @logger.info 'Found 0 Compositions'
        end
        @logger.debug ''

        # Inspect CPLs
        # FIXME and all over again ...
        audio_stats = Hash.new
        cpl_inspection_contexts = cpl_contexts.flatten
        cpl_context_counts = Hash.new( 0 )
        cpl_inspection_contexts.each { |context| cpl_context_counts[ context[ :cpl_id ] ] += 1 }
        cpl_titles = {}
        cpl_accounting = {
          :signed_cpl_ids => {},
          :verified_cpl_ids => {},
          :encrypted_cpl_ids => {},
          :info_cpl_ids => {}
        }
        cpl_inspection_contexts.each do |context|
          dictionary = context[ :dict ]
          cpl_id = context[ :cpl_id ]
          report = []
          if dictionary.include?( cpl_id )
            cpl_file = package dictionary[ cpl_id ]
            if File.exist?( cpl_file )
              xml = xml?( cpl_file )
              if xml
                title_node = xml.root.element_children.find { |node| node.name == 'ContentTitleText' && node.namespace&.href == xml.root.namespace&.href }
                cpl_titles[cpl_id] = title_node&.text.to_s

                cpl_context = {
                  :accounting => cpl_accounting,
                  :pkl_hashes => context[:pkl_hashes],
                  :pkl_asset_ids => context[:pkl_asset_ids],
                  :pkl_id => context[:pkl_id],
                  :resource_dict => context[:resource_dict],
                  :dict_label => options.as_asset_store ? 'asset-store dictionary' : "PKL #{ context[ :pkl_id ] } asset dictionary"
                }
                if cpl_context_counts[ cpl_id ] > 1
                  cpl_context[ :report_context ] = options.as_asset_store ? 'Asset-store context' : "PKL context: #{ context[ :pkl_id ] }"
                  cpl_context[ :summary_context ] = options.as_asset_store ? 'asset-store' : "PKL #{ context[ :pkl_id ].split( '-' ).first }"
                end
                _composition_summary, report, errors, hints, siginfo, info = cpl_inspect_xml( xml, dictionary, audio_stats, @package_dir, composition_summaries, errors, hints, siginfo, info, options, inspection_run, cpl_context )
              else
                errors << "PKL listed CPL is not XML ❌: #{ cpl_file }: #{ cpl_id }"
              end
            else
              report << "CPL file missing ❌: #{ cpl_file }"
            end
            report.map { |line| @logger.cpl line }
            @logger.cpl ''
          end
        end


        MetadataChecks.duplicate_titles(cpl_titles).each do |duplicate|
          message = "Identical ContentTitleText #{duplicate[:title].inspect} in distinct CPLs #{duplicate[:cpl_ids].join(', ')}; review version naming (advisory, not a specification violation)"
          hints << message
          duplicate[:cpl_ids].each do |id|
            inspection_run.add_check(inspection_run.compositions[id], :duplicate_title, :hint, message, duplicate)
          end
        end

        # prep for Info summary block
        pkls = pkls.flatten
        cpls = cpls.flatten
        execution_time_seconds = Time.now - @started_at
        execution_time = Timecode.new( execution_time_seconds.round, 60 ).to_s
        total_size = "#{ packages_size_actual == packages_size_listed ? packages_size_actual.to_k : packages_size_actual.to_k + ' (Listed total: ' + packages_size_listed.to_k + ')' }"
        pkls_signature_info = "#{ @signed_pkls_count } signed#{ @signed_pkls_count > 0 ? '/' + @signed_pkls_verified_count.to_s + ' verified' : '' }"
        pkls_signature_info += ' ❌' unless @signed_pkls_verified_count == @signed_pkls_count
        cpls_signature_info = "#{ @signed_cpls_count } signed#{ @signed_cpls_count > 0 ? '/' + @signed_cpls_verified_count.to_s + ' verified' : '' }"
        cpls_signature_info += ' ❌' unless @signed_cpls_verified_count == @signed_cpls_count
        cpls_encryption_info = "#{ cpls.size - @encrypted_compositions > 0 ? ( cpls.size - @encrypted_compositions ).to_s + ' plaintext/' : '' }#{ amount( 'KDM', @encrypted_compositions ) } required)"
        am_info =  "#{ amount( 'Assetmap', am_files ) }#{ am_candidates_rejects.any? ? ' (' + amount( 'candidate', am_files.size + am_candidates_rejects.size ) + '/' + amount( 'reject', am_candidates_rejects ) + ')' : '' }"
        pkl_info =  "#{ amount( 'Package', pkls ) } (#{ pkls_signature_info })"
        cpl_info =  "#{ amount( 'Composition', cpls ) } (#{ cpls_signature_info }, #{ cpls_encryption_info }"

        # Info summary block
        composition_summaries.each do |composition_summary|
          info << composition_summary_oneliner( composition_summary )
        end
        info << "#{ AppName } #{ AppVersion } (asdcplib #{ @asdcplib_version }, #{ RubyVersionPlatform }) on #{ datetime_friendly(@run_datetime) } (#{ execution_time })"
        info << "Inspected #{ Pathname( arg ).realpath }"
        info << "Found #{ amount( 'Package', pkls ) } with total size #{ total_size }"
        info << 'Hash checks skipped' if ( options.check_hashes == false && pkls.size > 0 )
        info << "Hash checks skipped for assets bigger than #{ @check_hashes_limit_nice }" if @check_hashes_limit_nice
        info << "Hash checks skipped by size for #{ amount( 'asset', @check_hashes_limit_hits ) } of #{ @check_hashes_hits + @check_hashes_limit_hits + @check_hashes_png_hits } total" if @check_hashes_limit_nice
        info << "PNG asset hash checks skipped (--np): #{ amount( 'asset', @check_hashes_png_hits ) }" if options.skip_png_hashes && options.check_hashes
        if options.schema_validate == false
          info << 'Schema checks skipped' unless am_files.empty?
        end
        if options.audio_analysis == false
          info << 'Audio analysis skipped' unless cpls.empty?
        end
        info << 'Found ' + [ am_info, pkl_info, cpl_info ].join( ', ' )
        info << "#{ amount( 'Error', errors ) }#{ errors.size == 0 ? ' ✅' : ' ❌' }, #{ amount( 'Hint', hints ) }"
        tfs_dashboard.final_summary( info ) if tfs_dashboard

        return { :errors => errors, :hints => hints, :siginfo => siginfo, :info => info, :am_files => am_files, :pkls => pkls, :cpls => cpls, :pkls_missing => pkls_missing, :cpls_missing => cpls_missing, :inspection_run => inspection_run }
      end # dcp_inspect


      end
    end
  end
end
