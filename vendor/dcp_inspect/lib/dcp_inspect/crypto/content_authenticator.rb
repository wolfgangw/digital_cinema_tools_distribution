# frozen_string_literal: true
require 'openssl'
require 'base64'
require_relative 'common_name'

module DcpInspect
  module Crypto
    # DCI DCSS 1.5 section 9.4.3.5(4)(a): exclusivity belongs to the
    # KDM-selected certificate anywhere in the CPL chain, not every leaf.
    module ContentAuthenticator
      module_function
      def thumbprint(cert)
        # ST 430-2 section 5.4: SHA-1 of the TBSCertificate contents, excluding
        # its DER tag/length. Neither the whole-certificate fingerprint nor dnQ.
        tbs = OpenSSL::ASN1.decode(cert.to_der).value.first
        Base64.strict_encode64(OpenSSL::Digest::SHA1.digest(tbs.value.map(&:to_der).join))
      end

      def assess(crypto, encrypted:, signed:, content_authenticator: nil)
        result = { status: :info, eligibility: :not_applicable, binding: :unchecked, candidates: [] }
        unless encrypted
          return result.merge(message: 'DCI ContentAuthenticator CS-only eligibility is not applicable to this plaintext CPL')
        end
        unless signed
          return result.merge(eligibility: :unchecked, message: 'DCI ContentAuthenticator eligibility unchecked: encrypted CPL has no inspected signature; KDM binding unchecked')
        end
        unless crypto && crypto.chain_verified && crypto.errors[:pre_context].empty?
          return result.merge(eligibility: :unchecked, message: 'DCI ContentAuthenticator eligibility unchecked: no usable verified CPL certificate chain; KDM binding unchecked')
        end
        candidates = crypto.context.select do |cert|
          parsed = CommonName.parse(cert.subject)
          parsed[:errors].empty? && parsed[:roles] == ['CS']
        end
        result[:candidates] = candidates.map { |cert| { subject: cert.subject.to_s, issuer: cert.issuer.to_s, serial: cert.serial.to_i.to_s, thumbprint: thumbprint(cert) } }
        result[:eligibility] = candidates.empty? ? :ineligible : :eligible
        unless content_authenticator.nil?
          begin
            binary = Base64.strict_decode64(content_authenticator.to_s.delete(" \t\r\n"))
            raise ArgumentError unless binary.bytesize == 20
          rescue ArgumentError
            return result.merge(status: :error, binding: :invalid, message: 'Invalid ContentAuthenticator: expected a base64-encoded 20-byte certificate thumbprint')
          end
          selected = crypto.context.find { |cert| Base64.strict_decode64(thumbprint(cert)) == binary }
          return result.merge(status: :error, binding: :mismatch, message: 'KDM ContentAuthenticator does not match any certificate in the CPL signer chain') unless selected
          eligible = candidates.include?(selected)
          return result.merge(status: eligible ? :ok : :error, binding: :matched,
            message: eligible ? 'KDM ContentAuthenticator matches a CS-only certificate in the CPL chain (DCI role requirement met)' : 'KDM ContentAuthenticator matches a certificate that is not CS-only (DCI DCSS 9.4.3.5(4)(a))')
        end
        if candidates.empty?
          result.merge(status: :error, message: 'DCI encrypted-CPL compatibility: no CS-only certificate in the signer chain can satisfy ContentAuthenticator (DCSS 9.4.3.5(4)(a)); KDM binding unchecked')
        else
          result.merge(message: 'DCI encrypted-CPL compatibility: CS-only ContentAuthenticator candidate present in signer chain; KDM binding unchecked (no KDM inspected)')
        end
      end
    end
  end
end
