# frozen_string_literal: true

module DcpInspect
  module Crypto
    # ST 430-2:2017 sections 5.3.4 and 6.2(8). Roles are case-sensitive;
    # unfamiliar roles remain present, including when checking exclusivity.
    module CommonName
      module_function
      def parse(name, strict: true)
        fields = name.to_a.select { |field| field[0] == 'CN' }
        result = { value: nil, roles: [], entity: nil, errors: [] }
        unless fields.size == 1
          result[:errors] << "Expected exactly one CommonName field; found #{fields.size}"
          return result
        end
        _, value, encoding = fields.first
        result[:value] = value
        role_text, separator, entity = value.partition('.')
        result[:roles] = role_text.split(' ')
        result[:entity] = entity
        if strict
          result[:errors] << 'CommonName contains characters outside the PrintableString repertoire' unless value.match?(/\A[A-Za-z0-9 '()+,\-.\/:=?]*\z/)
          result[:errors] << 'CommonName must be encoded as ASN.1 PrintableString' unless encoding == OpenSSL::ASN1::PRINTABLESTRING
          result[:errors] << 'CommonName must contain a period separating roles from a nonempty entity name' if separator.empty? || entity.empty?
          unless role_text.empty? || role_text.match?(/\A[A-Za-z]+(?: [A-Za-z]+)*\z/)
            result[:errors] << 'CommonName roles must be ASCII letters separated by single spaces'
          end
        end
        result
      end

      def findings(cert, type:, leaf:, desired_role: nil)
        strict = type == :smpte
        subject = parse(cert.subject, strict: strict)
        issuer = parse(cert.issuer, strict: strict)
        errors = subject[:errors].map { |m| "Subject: #{m}" } + issuer[:errors].map { |m| "Issuer: #{m}" }
        hints = []
        if leaf && strict
          errors << 'Role title missing in CommonName field of leaf certificate subject name' if subject[:roles].empty?
          if desired_role && !subject[:roles].include?(desired_role)
            errors << "#{desired_role} role missing in CommonName field of leaf certificate subject name (required by validation context)"
          end
        elsif !leaf && !subject[:roles].empty?
          if type == :interop
            errors << 'Role title present in CommonName field of Interop authority certificate'
          elsif strict
            hints << 'Authority CommonName contains roles: permitted by ST 430-2 processing rules, but differs from informative Annex A CA naming guidance'
          end
        end
        { errors: errors, hints: hints }
      end
    end
  end
end
