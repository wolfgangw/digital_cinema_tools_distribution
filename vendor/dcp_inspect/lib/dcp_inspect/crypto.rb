# frozen_string_literal: true

require "base64"
require "openssl"
require_relative "crypto/signer_identity"
require_relative "crypto/common_name"
require_relative "crypto/content_authenticator"

module DcpInspect
  module Crypto
    class SignerCompliance
      include DcpInspect::Support::TimeFormatting
      attr_reader :context, :errors, :hints, :siginfo, :crypto_context_valid, :type, :chain_verified
      def initialize(certs, desired_role: nil)
        @desired_role = desired_role
        crypto_context( certs )
      end

      def crypto_context( certs )
        @errors = { context: {}, pre_context: [] }
        @hints = { context: {} }
        @siginfo = { context: {}, expired_certs: [] }
        @chain_verified = false
        @context, @errors[ :pre_context ] = find_crypto_context( certs )
        if @errors[ :pre_context ].empty?
          @errors[ :context ], @hints[ :context ], @siginfo[ :context ], @siginfo[ :expired_certs ], @types_seen = check_compliance()
          if @errors[ :pre_context ].empty? and @errors[ :context ].values.flatten.empty? and @chain_verified == true
            if @types_seen.uniq.size == 1
              @type = @types_seen.first
              @crypto_context_valid = true
            else
              @type = 'Mixed'
              @errors[:context][@context.first.subject.to_s] << 'Mixed Interop/SMPTE certificate-chain profile'
              @crypto_context_valid = false
            end
          else
            @crypto_context_valid = false
          end
        else
          @crypto_context_valid = false
        end
      end # crypto_context

      def valid?
        @crypto_context_valid
      end

      def expired_certs?
        @siginfo[ :expired_certs ].any?
      end

      def messages
        return @errors[:pre_context] + ['Certificate-chain compliance unchecked: chain unavailable'] unless @errors[:pre_context].empty?
        msgs = Array.new
        @context.each_with_index do |cert, index|
          msgs << "Subject: #{ cert.subject.to_s }"
          msgs << "Issuer:  #{ cert.issuer.to_s }"
          unless @errors[ :context ].nil?
            if @errors[ :context ][ cert.subject.to_s ].empty?
              msgs << 'OK ✅'
            else
              msgs << "Not a #{ @types_seen[ index ] } compliant certificate: ❌"
              @errors[ :context][ cert.subject.to_s ].each do |error|
                msgs << "\t" + error
              end
            end
          end
        end
        msgs << "Chain signatures #{ @chain_verified == true ? 'verified' : 'verification failed ❌' }"
        if total_errors == 0
          msgs << "Compliant certificate chain found: #{ @type } (#{ context.to_a.size } certificates, 0 errors)"
        else
          msgs << "Not a compliant certificate chain ❌: #{ context.to_a.size } certificate#{ context.to_a.size != 1 ? 's' : '' } with #{ total_errors } error#{ total_errors != 1 ? 's' : '' }"
        end
        return msgs
      end

      def find_crypto_context( pems )
        context = Array.new
        pre_context_errors = Array.new

        pems.each do |pem|
          begin
            cert_obj = OpenSSL::X509::Certificate.new( pem )
            context << cert_obj
          rescue
            # catch all exceptions (scan or CertificateError) and move on
          end
        end

        # Find root ca and collect issuers
        # ruby version of CTP's dsig_cert.py
        root = nil
        issuer_map = Hash.new

        context.each do |cert|
          if cert.issuer.to_s == cert.subject.to_s
            if root
              pre_context_errors << 'Multiple self-signed (root) certificates found ❌'
              return [], pre_context_errors
            else
              root = cert
            end
          else
            issuer_map[ cert.issuer.to_s ] = cert
          end
        end
        if root == nil
          pre_context_errors << 'Self-signed root certificate not found ❌'
          return [], pre_context_errors
        end

        # sort
        tmp_list = Array.new
        tmp_list << root
        begin
          key = tmp_list.last.subject.to_s
          child = issuer_map[ key ]
          while child
            break if tmp_list.include?(child)
            tmp_list << child
            key = tmp_list.last.subject.to_s
            child = issuer_map[ key ]
          end
        rescue
          nil
        end # ruby version of CTP's dsig_cert.py

        if tmp_list.size == 1
          pre_context_errors << 'No issued certificates found ❌'
          return context, pre_context_errors
        end

        if context.size != tmp_list.size
          pre_context_errors << 'Certificates do not form a complete chain ❌'
          return context, pre_context_errors
        end
        # from here on 1st is leaf, 2nd .. n are intermediate ca's, last is self-signed root ca
        context = tmp_list.reverse
        return context, pre_context_errors
      end # find_crypto_context

      def check_compliance()
        context_errors = Hash.new
        context_hints = Hash.new
        context_siginfo = Hash.new
        context_siginfo_expired_certs = Array.new
        types_seen = Array.new
        @context.each_with_index do |member, index|
          cert = member
          type = nil
          errors = Array.new
          hints = Array.new
          siginfo = Array.new
          siginfo_expired_cert = false

          errors << 'Not a X509 certificate ❌' unless cert.is_a?( OpenSSL::X509::Certificate )
          # ctp sections:

          # 2.1.1 X.509 version 3
          errors << 'Not X509 version 3 ❌' unless cert.version == 2 # sic. versions 1 2 3 -> 0 1 2

          # 2.1.1 Issuer and subject present
          errors << 'Issuer missing ❌' unless cert.issuer.is_a?( OpenSSL::X509::Name )
          errors << 'Subject missing ❌' unless cert.subject.is_a?( OpenSSL::X509::Name )

          #
          # Pick up CN and DNQ content, make a moniker
          # to use for better identification in messages
          # This was ad-hoc-triggered by the CS expiry events around 2023-12-31
          # FIXME actually use it everywhere
          # FIXME See 2.1.11 for the proper dnQualifier checks
          # FIXME which include the crucial mismatch check for calc/field values
          # FIXME Move 2.1.11 to here to do it right
          #
          cert_cn = ''
          cert_dnq = ''
          issuer_dnq = ''
          begin
            cert_cn = find_field( 'CN', cert.subject )[0][1]
            cert_dnq = find_field( 'dnQualifier', cert.subject )[0][1]
            issuer_dnq = find_field( 'dnQualifier', cert.issuer )[0][1]
          rescue
            errors << "Fields missing ❌: Could not pick CN and dnQualifier from #{ cert.subject }"
          end
          cert_moniker = "(#{ cert_dnq[0..5] }.. < #{ issuer_dnq[0..5] }..) #{ cert_cn }"


          # * 2.1.2 Signature algorithm
          case cert.signature_algorithm
          when 'sha256WithRSAEncryption'
            type = :smpte
          when 'sha1WithRSAEncryption'
            type = :interop
          else
            errors << 'Signature algorithm not sha256WithRSAEncryption or sha1WithRSAEncryption ❌'
          end

          # 2.1.3
          # Implicitly checked above

          # * 2.1.4 Serial number field non-negative integer less or equal to 64 or 160 bits respectively
          #
          case type
          when :smpte
            errors << 'Serial number not in valid range ❌' unless 0 <= cert.serial.to_i and cert.serial.to_i <= 2 ** 64
            hints << "Certificate #{ cert_moniker.inspect } serial number #{ cert.serial.to_i } exceeds Dolby DSS220 erroneous upper limit of 2**32-1" unless cert.serial.to_i < 2 ** 32
          when :interop
            errors << 'Serial number not in valid range ❌' unless 0 <= cert.serial.to_i and cert.serial.to_i <= 2 ** 160
            hints << "Certificate #{ cert_moniker.inspect } serial number #{ cert.serial.to_i } exceeds Dolby DSS220 erroneous upper limit of 2**32-1" unless cert.serial.to_i < 2 ** 32
          else
            errors << 'Serial number not checked (Certificate type has not been established) ❌'
          end

          # 2.1.5 SubjectPublicKeyInfo field modulus 2048 bit and e == 65537
          errors << 'Modulus not 2048 bits long ❌' unless cert.public_key.n.to_i.size == 256 # 'n' is modulus (as OpenSSL::BN)
          errors << 'Public exponent not 65537 ❌' unless cert.public_key.e == 65537 # 'e' is public exponent (OpenSSL::BN)

          # 2.1.6 Deleted (in CTP 1.1) section

          # 2.1.7 Validity field (not before, not after)
          #
          # Note on Ruby version 1.8.7:
          #
          # UTC time > jan 19th 2038 is broken in ruby 1.8.7 on 32 bit systems (See https://bugs.ruby-lang.org/issues/5885)
          # See {"o"=>"DC256.Cinea.Com"} {"ou"=>"Root-CA.DC256.Cinea.Com"} {"cn"=>".Cinea.Root-CA.0"} {"dnq"=>"NFkBZDCGa7KpLK0PhZNCt40dDi8="} {"not_before"=>2006-05-12 16:08:58 UTC} {"not_after"=>2041-05-01 00:00:00 UTC} for a valid X509 cert exceeding 32 bit time_t.
          # See COFD-3D_FTR-8_C_EN-XX_US_51_2K_20110308_DLB_i3D for a package with NFkBZDCGa7KpLK0PhZNCt40dDi8=.
          # See DC_Signer_Crypto_Compliance Section 2.1.17 for another spot where this matters.
          #
          begin
            errors << 'Not before field missing ❌' if cert.not_before.nil?
            errors << 'Not after field missing ❌' if cert.not_after.nil?
            errors << 'Not before field is not UTC ❌' unless cert.not_before.utc?
            errors << 'Not after field is not UTC ❌' unless cert.not_after.utc?
          rescue Exception => e
            errors << "Internal error: Skip DC_Signer_Crypto_Compliance Section 2.1.7 Validity: RUBY_VERSION #{ RUBY_VERSION } on 32 bit systems broken for UTC times > Jan 19th 2038. Inspect certificate manually ❌" if e.class == ArgumentError
          end

          # Check X.509 extensions
          required_oids = %w( basicConstraints keyUsage authorityKeyIdentifier )
          additional_oids = Array.new

          cert.extensions.each do |x|
            if required_oids.include?( x.oid )
              required_oids.delete( x.oid )
              values = extension_values( x.value )

              case x.oid

              # 2.1.8 AuthorityKeyIdentifier field present
              when 'authorityKeyIdentifier'
                nil # 2.1.8 checks for presence only. Omission in CTP?

              # 2.1.9 KeyUsage field
              when 'keyUsage'
                if index == 0 # leaf cert
                  errors << 'digitalSignature missing from keyUsage ❌' unless values.include?( 'Digital Signature' )
                  errors << 'keyEncipherment missing from keyUsage ❌' unless values.include?( 'Key Encipherment' )
                else # ca's
                  errors << 'keyCertSign missing from keyUsage ❌' unless values.include?( 'Certificate Sign' )
                end

              # * 2.1.10 basicConstraints field
              when 'basicConstraints'
                if index == 0 # leaf cert
                  errors << "CA true in potential #{ type } leaf certificate ❌" unless values.include?( 'CA:FALSE' )
                  case type
                  when :smpte
                    if values.find { |v| v.match( /pathlen:[^0]/ ) }
                      errors << "Pathlen present and non-zero in potential #{ type } leaf certificate ❌"
                    end
                  when :interop
                    if values.find { |v| v.match( /pathlen:[^0]/ ) }
                      errors << "Pathlen present and non-zero in potential #{ type } leaf certificate ❌"
                    end
                  end
                else # ca's
                  errors << 'basicConstraints not marked critical ❌' unless x.critical?
                  errors << 'CA false for authority certificate ❌' unless values.include?( 'CA:TRUE' )
                  if ! values.find { |v| v.match( /pathlen:\d+/ ) }
                    # FIXME If the value in pathlen is negative the regexp above will not match
                    # and thus trigger the error but the message will be misleading
                    errors << 'Pathlen missing for authority certificate ❌'
                  end
                end
              end # case oid
            else
              additional_oids << x # see 2.1.15 checks
            end # required oid
          end # extensions
          errors << "Extensions #{ required_oids.join( ', ' ) } missing ❌" unless required_oids.empty?

          # 2.1.11 Public key thumbprint dnQualifier
          #
          if RUBY_VERSION < '1.9.3'
            # works for rubies < 1.9.3:
            asn1 = Base64.decode64( cert.public_key.to_pem.split( "\n" )[ 1 .. -2 ].join )
            dnq_calc = Base64.encode64( OpenSSL::Digest.new( 'sha1', asn1 ).digest ).chomp
          else
            # rubies >= 1.9.3 changed the default encoding of public key so do this instead:
            pkey_der = OpenSSL::ASN1::Sequence( [ OpenSSL::ASN1::Integer( cert.public_key.n ), OpenSSL::ASN1::Integer( cert.public_key.e ) ] ).to_der
            dnq_calc = Base64.encode64( OpenSSL::Digest.new( 'sha1', pkey_der ).digest ).chomp
          end
          #
          field_dnq = find_field( 'dnQualifier', cert.subject )
          if field_dnq.empty?
            errors << 'dnQualifier field missing in subject name ❌'
          elsif field_dnq.size > 1
            errors << 'More than 1 dnQualifier field present ❌'
          else
            dnq_cert = field_dnq.first[ 1 ]
            if dnq_cert.empty?
              errors << 'dnQualifier missing in subject name ❌'
            end
            if dnq_calc != dnq_cert
              errors << 'dnQualifier mismatch ❌'
            end
          end

          # 2.1.12 OrganizationName field present in issuer and subject and identical
          field_o_issuer = find_field( 'O', cert.issuer )
          field_o_subject = find_field( 'O', cert.subject )
          if field_o_issuer.empty?
            errors << 'Organization name field missing in issuer name ❌'
          elsif field_o_issuer.size > 1
            errors << 'More than 1 Organization name field present in issuer name ❌'
          else
            o_issuer = field_o_issuer.first[ 1 ]
          end
          if field_o_subject.empty?
            errors << 'Organization name missing in subject name ❌'
          elsif field_o_subject.size > 1
            errors << 'More than 1 Organization name field present in subject name ❌'
          else
            o_subject = field_o_subject.first[ 1 ]
          end
          unless o_issuer.nil? and o_subject.nil?
            if o_issuer != o_subject
              errors << 'Organization name issuer/subject mismatch ❌'
            end
          end

          # 2.1.13 OrganizationUnitName field
          field_ou_issuer = find_field( 'OU', cert.issuer )
          field_ou_subject = find_field( 'OU', cert.subject )
          if field_ou_issuer.empty?
            errors << 'OrganizationUnit field missing in issuer name ❌'
          elsif field_ou_issuer.size > 1
            errors << 'More than 1 OrganizationUnit fields present in issuer name ❌'
          else
            ou_issuer = field_ou_issuer.first[ 1 ]
          end
          if field_ou_subject.empty?
            errors << 'OrganizationUnit field missing in subject name ❌'
          elsif field_ou_subject.size > 1
            errors << 'More than 1 OrganizationUnit fields present in subject name ❌'
          else
            ou_subject = field_ou_subject.first[ 1 ]
          end
          if ou_issuer.nil?
            errors << 'OrganizationUnit name of issuer empty ❌'
          end
          if ou_subject.nil?
            errors << 'OrganizationUnit name of subject empty ❌'
          end

          # Certificate syntax/base role rules are separate from DCI KDM binding.
          ca = cert.extensions.any? { |ext| ext.oid == 'basicConstraints' && ext.value.match?(/CA:TRUE/) }
          cn = CommonName.findings(cert, type: type, leaf: !ca, desired_role: @desired_role)
          errors.concat(cn[:errors])
          hints.concat(cn[:hints])

          # 2.1.15 unrecognized x509v3 extensions not marked critical
          additional_oids.each do |x|
            errors << 'Additional, non-required X.509v3 extension is marked critical ❌' if x.critical?
          end

          #
          # CTP section 2.2 Certificate Decoder Behavior
          #
          # 2.2.6 Validity Date Check
          #
          # FIXME See https://github.com/wolfgangw/backports/issues/104
          # FIXME Pulling in 2.2.6 Validity Date Check
          # FIXME This is and will be biting a couple of outfits
          # FIXME Update 05.01.2024 affected systems: some Sonys, some GDCs, some pre-09.2023 Christies
          # FIXME This needs a lot of refinement but gets it done now
          #
          begin
            now_dt = DateTime.now
            cert_not_before_dt = time_to_datetime(cert.not_before)
            cert_not_after_dt = time_to_datetime(cert.not_after)
            if cert_not_after_dt < now_dt
              siginfo << "Certificate #{ cert_moniker.inspect } expired #{ distance_of_time_in_words( cert_not_after_dt, now_dt ) } ago (#{ datetime_friendly_mmmddyyyy cert_not_before_dt }-#{ datetime_friendly_mmmddyyyy cert_not_after_dt })"
              siginfo_expired_cert = cert
            else
              siginfo << "Certificate #{ cert_moniker.inspect } will expire in #{ distance_of_time_in_words( cert_not_after_dt, now_dt ) } (#{ datetime_friendly_mmmddyyyy cert_not_before_dt }-#{ datetime_friendly_mmmddyyyy cert_not_after_dt })"
            end
          rescue Exception => e
            errors << e.message
          end

          context_errors[ cert.subject.to_s ] = errors
          context_hints[ cert.subject.to_s ] = hints
          context_siginfo[ cert.subject.to_s ] = siginfo
          context_siginfo_expired_certs << siginfo_expired_cert if siginfo_expired_cert

          types_seen << type
        end # @context.each

        # 2.1.16 signature verification. verify chain
        @chain_verified, context_errors = verify_cert_chain( @context, context_errors )

        # 2.1.17 Chain complete? Validity period of child cert contained within validity of parent? Root ca valid?
        # The chain completeness and root ca checks are implicit in crypto_context() which leaves validity containment checks:
        @context.each_with_index do |cert, index|
          break if index == @context.size - 1 # root ca
          begin
            if ! ( cert.not_before >= @context[ index + 1 ].not_before and cert.not_after <= @context[ index + 1 ].not_after )
              context_errors[ cert.subject.to_s ] << "Validity period not contained within parent certificate's validity period ❌"
            end
          rescue Exception => e
            context_errors[ cert.subject.to_s ] << "Internal error: Skip DC_Signer_Crypto_Compliance Section 2.1.17 Chain completeness: RUBY_VERSION #{ RUBY_VERSION } on 32 bit systems broken for UTC times > Jan 19th 2038. Inspect certificate manually ❌" if e.class == ArgumentError
          end
        end
        return context_errors, context_hints, context_siginfo, context_siginfo_expired_certs, types_seen
      end # check_compliance

      # Verify a sorted certificate chain
      def verify_cert_chain( certs, context_errors )
        certs = certs.reverse
        verification = Array.new
        certs.each_with_index do |cert, index|
          if index == 0 then issuer = cert else issuer = certs[ index - 1 ] end
          begin
            check = cert.verify issuer.public_key
            context_errors[ cert.subject.to_s ] << 'Verification with issuer public key failed ❌' if check == false
            verification << check
          rescue Exception => e
            context_errors[cert.subject.to_s] << "Verification with issuer public key failed: #{e.message}"
            verification << false
          end
        end
        if verification.uniq.size == 1 and verification.first == true
          return true, context_errors
        else
          return false, context_errors
        end
      end

      def find_field( fieldname, x509_name )
        x509_name.to_a.find_all { |e| e.first.match '^' + fieldname + '$' }
      end

      def extension_values( string )
        string.split( ', ' )
      end

      def each
        @context.each {|f| yield( f ) }
      end

      def to_a
        @context.dup
      end

      def total_errors
        @errors[:pre_context].size + @errors[:context].values.flatten.size
      end
    end # DC_Signer_Crypto_Compliance


    class SignatureVerification
      attr_reader :messages, :signer_node, :signature_node, :crypto, :reference_digests_check, :signature_value_check, :identity_errors

      def initialize(doc, desired_role: nil)
        @desired_role = desired_role
        @messages = Array.new
        @identity_errors = []
        @signer_node = nil
        @signature_node = nil
        @crypto = nil
        @reference_digests_check = false
        @signature_value_check = false
        signature_verify( doc )
        report
      end

      def verified?
        @verified
      end

      def signed?
        @signature_node && ! @signature_node.empty?
      end

      def check_status
        return :info unless signed?

        verified? && @identity_errors.empty? && @crypto&.valid? ? :ok : :error
      end

      def verification_details
        { cryptographic_signature: signed? ? (verified? ? :ok : :error) : :unchecked,
          certificate_compliance: @crypto ? (@crypto.valid? ? :ok : :error) : :unchecked,
          signer_identity: @crypto && !@crypto.context.empty? && @crypto.errors[:pre_context].empty? ? (@identity_errors.empty? ? :ok : :error) : :unchecked,
          desired_role: @desired_role }
      end

      def signer_name
        if @crypto
          @crypto.context.first.subject.to_s unless @crypto.context.empty?
        else
          ''
        end
      end
      def signer_issuer
        if @crypto
          @crypto.context.first.issuer.to_s unless @crypto.context.empty?
        else
          ''
        end
      end

      def report
        if @signature_node.size == 1
          case @reference_digests_check
          when true
            @messages << 'Document and SignedInfo match'
            case @signature_value_check
            when true
              @messages << 'Signature value and SignedInfo match'
            when false
              @messages << 'Signature value and SignedInfo do not match ❌'
            end

          when false
            @messages << 'Document and SignedInfo do not match ❌'
            case @signature_value_check
            when true
              @messages << 'Signature value and SignedInfo match'
            when false
              @messages << 'Signature value and SignedInfo do not match ❌'
            end
          end

          if @reference_digests_check and @signature_value_check
            @verified = true
            @messages << if !@identity_errors.empty?
              'Signature cryptographically verified; Signer identity mismatch ❌'
            elsif !@crypto&.valid?
              'Signature cryptographically verified; certificate/content-signer validation failed ❌'
            else
              'Signature check: OK ✅'
            end
          else
            @verified = false
            @messages << 'Signature check: Verification failure ❌'
          end
        end
      end

      #
      # FIXME
      # Looking only at the first prefix returned from collect_all_namespaces_href_keys
      # for a given namespace will fall on its nose when there would be multiple prefixes
      # for the same namespace. E.g. I think in a Signature it would be entirely valid to
      # use different prefixes for different portions, all evaluating to the same namespace.
      #
      # Good enough for now but ktfim
      #
      def namespace_prefix( doc, ns )
        doc_ns = doc.collect_all_namespaces_href_keys
        if doc_ns.key?( ns )
          doc_ns[ ns ].first.nil? ? 'xmlns' : doc_ns[ ns ].first
        else
          'xmlns'
        end
      end

      def signature_namespace_and_prefix( doc )
        # If Signature's namespace is not in doc's namespace collection then it will be either
        #   * in Ns_Xmldsig declared as default namespace for Signature scope
        #   * or whacked beyond recognition
        doc_ns = doc.collect_namespaces
        if RUBY_VERSION < '1.9'
          # Hash#index will be deprecated in the ruby 1.9.x series. Is in here for 1.8.x
          if doc_ns.index( DcpInspect::Inspection::Vocabulary::Ns_Xmldsig )
            prefix = doc_ns.index( DcpInspect::Inspection::Vocabulary::Ns_Xmldsig ).split( 'xmlns:' ).last
          else
            prefix = 'xmlns'
          end
        else
          if doc_ns.key( DcpInspect::Inspection::Vocabulary::Ns_Xmldsig )
            prefix = doc_ns.key( DcpInspect::Inspection::Vocabulary::Ns_Xmldsig ).split( 'xmlns:' ).last
          else
            prefix = 'xmlns'
          end
        end
        sig_ns = { prefix => DcpInspect::Inspection::Vocabulary::Ns_Xmldsig }
        return sig_ns, prefix
      end

      # Will return true/false for completing the evaluation
      # Actual verification results implied by @reference_digests_check and @signature_value_check
      def signature_verify( doc )
        # 1. Figure out signature namespace prefix
        sig_ns, prefix = signature_namespace_and_prefix( doc )

        # 2.a Signer present?
        @signer_node = doc.xpath( "//#{ namespace_prefix( doc, doc.root.namespace.href ) }:Signer" )
        if @signer_node.size != 1
          @messages << "#{ @signer_node.size == 0 ? 'No' : @signer_node.size } Signer node#{ @signer_node.size > 1 ? 's' : '' } found"
        end

        # 2.b Signature present?
        @signature_node = doc.xpath( "//#{ prefix }:Signature", sig_ns )
        if @signature_node.size != 1
          @messages << "#{ @signature_node.size == 0 ? 'No' : @signature_node.size } Signature node#{ @signature_node.size > 1 ? 's' : '' } found"
        end

        # 2.c Abort if none or more than 1 Signer or Signature node
        return false if ( @signer_node.size != 1 or @signature_node.size != 1 )

        # 3. Extract and check signer certs
        certs = extract_certs( doc, sig_ns, prefix )
        @crypto = SignerCompliance.new(certs, desired_role: @desired_role)

        if ! @crypto.valid?
          if ! @crypto.errors[ :pre_context ].empty?
            @crypto.errors[ :pre_context ].each do |e|
              @messages << e
            end
            return false
          else
            # Compliance issues in the extracted certs.
            # List those errors but then try to continue anyway,
            # thus allowing for inspection of compliance issues and signature in context.
            @crypto.messages.each do |e|
              @messages << e
            end
          end
        else # cc is valid
          @messages << "Certificate chain is complete and compliant (#{ @crypto.type })"
        end

        # 3.a Might check here whether the signer chain is known, trustworthy etc.
        #
        # See 3 for @crypto validity hop-over
        #

        @identity_errors = SignerIdentity.errors(@signer_node.first, @crypto.context.first)
        @messages.concat(@identity_errors)

        # 4. Get signer's public key
        pub_k = @crypto.context.first.public_key

        # 5. Check references and signature value
        @reference_digests_check = check_references( doc, sig_ns, prefix )
        @signature_value_check = check_signature_value( doc, sig_ns, prefix, pub_k )

        return true
      end # signature_verify

      def check_signature_value( doc, sig_ns, prefix, pub_k )
        sig_algo = doc_signature_method_algorithm( doc, sig_ns, prefix )
        unless sig_algo
          @messages << 'Cannot verify signature value: SignatureMethod Algorithm missing ❌'
          return false
        end

        sig_digest_algo = sig_algo.split( 'rsa-' ).last
        signature_value_doc = extract_signature_value( doc, sig_ns, prefix )
        unless signature_value_doc
          @messages << 'Cannot verify signature value: SignatureValue element missing ❌'
          return false
        end

        signature_value_doc_octets = signature_value_doc.size
        pub_k_octets = pub_k.n.to_i.size
        if signature_value_doc_octets != pub_k_octets
          @messages << "Invalid signature ❌: decoded SignatureValue has #{ signature_value_doc.size } octets (should have #{ pub_k.n.to_i.size } RSA modulus octets)"
          return false
        end
        signed_info_c14n_xml = signed_info_c14n( doc, sig_ns, prefix )
        unless signed_info_c14n_xml
          @messages << 'Cannot verify signature value: SignedInfo element missing ❌'
          return false
        end

        signed_info_digest_calc = b64_enc( digest( sig_digest_algo, signed_info_c14n_xml ) )
        signed_info_digest_doc  = b64_enc( decode_sig_value( signature_value_doc, sig_digest_algo, pub_k ) )
        @messages << "SignedInfo Digest calc:    #{ signed_info_digest_calc } (SignatureMethod Algorithm=#{ sig_algo })"
        @messages << "SignedInfo Digest decoded: #{ signed_info_digest_doc  } (SignatureMethod Algorithm=#{ sig_algo })"

        return ( signed_info_digest_calc == signed_info_digest_doc )
      end

      def check_references( doc, sig_ns, prefix )
        check = true
        references = doc_references( doc, sig_ns, prefix )
        check = false if references.size == 0
        @messages << "Found #{ references.size } reference#{ references.size != 1 ? 's' : '' }"
        references.each do |ref|
          digest_algo = doc_reference_digest_method_algorithm( ref, sig_ns, prefix )
          digest_doc = doc_reference_digest_value( ref, sig_ns, prefix )
          unless digest_algo && digest_doc
            @messages << 'Cannot verify reference digest: DigestMethod or DigestValue missing ❌'
            check = false
            next
          end

          if ref.attributes.size == 1 and ref.attributes[ 'URI' ]
            uri = ref.attributes[ 'URI' ].value
            case uri
            when ""
              ref_xml = strip_signature( doc.dup, sig_ns, prefix ).canonicalize
            else
              if uri =~ /^#ID_/
                ref_xml = extract_uri( doc, uri ).canonicalize
              else
                @messages << 'Reference URI not valid ❌'
                check = false
                next
              end
            end
            digest_calc = b64_enc( digest( digest_algo, ref_xml ) )
            @messages << "URI=#{ uri.empty? ? '""' : uri } Digest calc: #{ digest_calc } (DigestMethod Algorithm=#{ digest_algo })"
            @messages << "URI=#{ uri.empty? ? '""' : uri } Digest doc:  #{ digest_doc  } (DigestMethod Algorithm=#{ digest_algo })"
            if digest_calc == digest_doc
              @messages << 'Reference digest value correct'
            else
              @messages << 'Reference digest value not correct ❌'
              check = false
            end
          else
            # not reached if doc was validated against schema
            @messages << 'Reference has more than 1 attribute ❌'
          end
        end
        return check
      end

      def attribute_value( element, attr_name, element_label = nil )
        unless element
          @messages << "#{ element_label || 'Element' } node missing ❌"
          return nil
        end

        attribute = element.attributes[ attr_name ]
        unless attribute
          label = element_label || element.name
          @messages << "#{ label } missing @#{ attr_name } attribute ❌"
          return nil
        end

        attribute.text
      end

      def doc_signature_method_algorithm( doc, sig_ns, prefix )
        signature_method = doc.at_xpath( "//#{ prefix }:SignatureMethod", sig_ns )
        algorithm = attribute_value( signature_method, 'Algorithm', 'SignatureMethod' )
        return nil unless algorithm

        signature_method_algorithm( algorithm )
      end

      def doc_references( doc, sig_ns, prefix )
        doc.xpath( "//#{ prefix }:SignedInfo/#{ prefix }:Reference", sig_ns )
      end

      def doc_reference_digest_method_algorithm( reference, sig_ns, prefix )
        digest_method = reference.at_xpath( "#{ prefix }:DigestMethod", sig_ns )
        algorithm = attribute_value( digest_method, 'Algorithm', 'DigestMethod' )
        return nil unless algorithm

        digest_method_algorithm( algorithm )
      end

      def doc_reference_digest_value( reference, sig_ns, prefix )
        digest_value_node = reference.at_xpath( "#{ prefix }:DigestValue", sig_ns )
        unless digest_value_node
          @messages << 'Reference missing DigestValue element ❌'
          return nil
        end

        digest_value_node.text
      end

      def signed_info_c14n( doc, sig_ns, prefix )
        signed_info_node = doc.at_xpath( "//#{ prefix }:SignedInfo", sig_ns )
        unless signed_info_node
          @messages << 'SignedInfo element missing ❌'
          return nil
        end

        signed_info_node.canonicalize
      end

      def digest( hash_id, m )
        OpenSSL::Digest.new( hash_id, m ).digest
      end

      def signature_method_algorithm( id )
        {
          'http://www.w3.org/2000/09/xmldsig#rsa-sha1' => 'rsa-sha1',
          'http://www.w3.org/2001/04/xmldsig-more#rsa-sha256' => 'rsa-sha256'
        }[ id ]
      end

      def digest_method_algorithm( id )
        {
          'http://www.w3.org/2000/09/xmldsig#sha1' => 'sha1',
          'http://www.w3.org/2001/04/xmlenc#sha256' => 'sha256'
        }[ id ]
      end

      def emsa_pkcs1_v1_5_decode( hash_id, m )
        hash_size = digest( hash_id, '' ).size
        m[ m.size - hash_size, hash_size ]
      end

      # See rsa gem
      def os2ip( octet_string )
        octet_string.bytes.inject( 0 ) { |n, b| ( n << 8 ) + b }
      end

      # See rsa gem
      def i2osp( x, len = nil )
        raise ArgumentError, 'integer too large' if len && x >= 256 ** len
        StringIO.open do |buffer|
          while x > 0
            b = ( x & 0xFF ).chr
            x >>= 8
            buffer << b
          end
          s = buffer.string
          # FIXME
          if s.respond_to?( :force_encoding )
            s.force_encoding( Encoding::BINARY )
          end
          s.reverse!
          s = len ? s.rjust( len, "\0" ) : s
        end
      end

      # See rsa gem. note the bn modification here
      def modpow( base, exponent, modulus )
        result = 1
        while exponent > 0
          result = ( base * result ) % modulus unless ( ! exponent.bit_set? 0 )
          base = ( base * base ) % modulus
          exponent >>= 1
        end
        result
      end

      def rsavp1( pub_k, s )
        modpow( s, pub_k.e, pub_k.n )
      end

      def extract_certs( doc, sig_ns, prefix )
        certs = Array.new
        doc.xpath( "//#{ prefix }:X509Certificate", sig_ns ).each do |c|
          begin
            pem = pemify( c.text )
            certs << OpenSSL::X509::Certificate.new( pem )
          rescue Exception => e
            @messages << e.inspect
          end
        end
        certs
      end

      def pemify( string )
        [
          '-----BEGIN CERTIFICATE-----',
          string.gsub( /[\r ]+/, '' ).split( "\n" ).join.split( /(.{64})/ ).reject { |e| e.empty? },
          '-----END CERTIFICATE-----'
        ].flatten.join( "\n" )
      end

      def decode_sig_value( value, sig_digest_algo, pub_k )
        m = rsavp1( pub_k, os2ip( value ) )
        emsa_pkcs1_v1_5_decode( sig_digest_algo, i2osp( m, pub_k.n.to_i.size ) )
      end

      def strip_signature( doc, sig_ns, prefix )
        signature_element = doc.at_xpath( "//#{ prefix }:Signature", sig_ns )
        signature_element.remove
        doc
      end

      def extract_uri( doc, uri )
        # See kdms/kdm_19400_8a1ace55-3953-4a6a-9f74-becc1d42af69_97f83429b5258215db5f96e79c8cbb4c1f2c8c8d.xml,
        # a dolby KDM with prefixed children, like "etm:AuthenticatedPublic".
        # Iterating children to pick up uri because I don't know a simpler way for now
        requested_node_name = uri.split( '#ID_' ).last
        doc.root.children.each do |child|
          if child.node_name and child.node_name == requested_node_name
            prefix = child.namespace.prefix
            return doc.at_xpath( "//#{ prefix.nil? ? 'xmlns:' : prefix + ':' }#{ requested_node_name }[ @Id = '#{ uri[ 1 .. -1 ] }' ]" )
          end
        end
      end

      def b64_enc( octet_string )
        Base64.encode64( octet_string ).chomp
      end
      def b64_dec( string )
        Base64.decode64 string
      end

      def extract_signature_value( doc, sig_ns, prefix )
        b64_dec( doc.at_xpath( "//#{ prefix }:SignatureValue", sig_ns ).text.split( "\n" ).join )
      end

    end # DC_Signature_Verification


  end
end
