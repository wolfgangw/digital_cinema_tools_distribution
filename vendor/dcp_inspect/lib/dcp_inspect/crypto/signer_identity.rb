# frozen_string_literal: true

module DcpInspect
  module Crypto
    module SignerIdentity
      NS = { 'ds' => 'http://www.w3.org/2000/09/xmldsig#' }.freeze
      module_function

      # Compare RDN sequences, preserving grouping and order but ignoring ASN.1
      # string encoding differences (e.g. PrintableString versus UTF8String).
      def distinguished_name(name)
        OpenSSL::ASN1.decode(name.to_der).value.map do |rdn|
          rdn.value.map { |attribute| [attribute.value[0].oid, attribute.value[1].value] }.sort
        end
      end

      def split_name(text, separator)
        parts = [String.new]
        escaped = quoted = false
        text.each_char do |char|
          if !escaped && !quoted && char == separator
            parts << String.new
          else
            parts.last << char
          end
          if escaped
            escaped = false
          elsif char == '\\'
            escaped = true
          elsif char == '"'
            quoted = !quoted
          end
        end
        raise ArgumentError, 'unterminated escape or quoted value' if escaped || quoted
        parts
      end

      def parse_name(text)
        # Ruby's whole-name parser rejects multi-valued RDNs. Let OpenSSL
        # decode each attribute while retaining its RDN grouping ourselves.
        split_name(text, ',').reverse.map do |rdn|
          split_name(rdn, '+').flat_map do |attribute|
            # Accept legacy separator spacing (RFC 2253 section 4). Strip
            # only before the attribute type, never from the value: escaped
            # or quoted value spaces remain part of the identity. This parses
            # a copy of the name and does not alter the signed XML.
            attribute = attribute.sub(/\A[ \t\r\n]+/, '')
            # OpenSSL emits unescaped '=' in values (notably base64 dnQ),
            # allowed by RFC 4514. Ruby's older RFC 2253 parser rejects it.
            # Escape only unescaped value equals; retain all other validation.
            type, delimiter, value = attribute.partition('=')
            raise ArgumentError, 'missing attribute value delimiter' if delimiter.empty?
            escaped = false
            value = value.each_char.map do |char|
              output = char == '=' && !escaped ? '\\=' : char
              escaped = !escaped && char == '\\'
              output
            end.join
            distinguished_name(OpenSSL::X509::Name.parse_rfc2253("#{type}=#{value}")).flatten(1)
          end.sort
        end
      end

      def errors(signer, certificate)
        return ['Signer identity cannot be compared: signing certificate unavailable'] unless certificate
        return ['Signer identity missing'] unless signer

        findings = []
        issuer = signer.xpath('ds:X509Data/ds:X509IssuerSerial/ds:X509IssuerName', NS)
        serial = signer.xpath('ds:X509Data/ds:X509IssuerSerial/ds:X509SerialNumber', NS)
        subject = signer.xpath('ds:X509Data/ds:X509SubjectName', NS)
        findings << 'Signer X509IssuerName must occur exactly once' unless issuer.size == 1
        findings << 'Signer X509SerialNumber must occur exactly once' unless serial.size == 1
        if serial.size == 1
          value = serial.first.text.strip
          if !value.match?(/\A\+?\d+\z/)
            findings << 'Signer X509SerialNumber is not a nonnegative integer'
          elsif value.to_i != certificate.serial.to_i
            findings << "Signer serial mismatch: X509SerialNumber #{value}; certificate #{certificate.serial}"
          end
        end
        [[issuer, certificate.issuer, 'issuer'], [subject, certificate.subject, 'subject']].each do |nodes, expected, label|
          nodes.each do |node|
            begin
              actual = parse_name(node.text.strip)
              unless actual == distinguished_name(expected)
                findings << "Signer #{label} name mismatch: XML #{node.text.inspect}; certificate #{expected.to_s(OpenSSL::X509::Name::RFC2253).inspect}"
              end
            rescue OpenSSL::X509::NameError, OpenSSL::ASN1::ASN1Error, ArgumentError => error
              findings << "Signer #{label} name is not a valid distinguished name: #{error.message}"
            end
          end
        end
        findings
      end
    end
  end
end
